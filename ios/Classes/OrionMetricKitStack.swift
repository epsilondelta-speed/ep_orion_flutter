import Foundation

/// OrionMetricKitStack (1.2.40) — turns a MetricKit call-stack tree into the
/// stack an `appIosdiagnostic` beacon carries, and fingerprints it.
///
/// Foundation only, deliberately: no MetricKit, UIKit or Flutter types. That
/// keeps it unit-testable with plain `swiftc` (scripts/verify/
/// test_metrickit_stack.sh) — MetricKit cannot deliver a payload to a
/// simulator, so this is the only place the logic can be exercised off-device.
///
/// WHY 1.2.40 EXISTS (the defect it fixes)
///   MetricKit builds call-stack trees in TWO opposite orientations:
///
///     • crash / watchdog (`callStackPerThread: true`) — the root frame is the
///       crashing frame and `subFrames` walk OUTWARDS to the thread entry.
///       Walking root → subFrames yields leaf first. Correct.
///     • hang / CPU / disk-write exceptions — an aggregated sample profile.
///       The root frame is the thread ENTRY (`dyld` for the main thread,
///       `libsystem_pthread` for a worker) and `subFrames` walk INWARDS to the
///       callee. Walking root → subFrames yields the entry first.
///
///   1.2.29–1.2.39 walked every tree root → subFrames and kept the first 20
///   frames. For the second kind that meant: `crashLoc` was the thread entry,
///   the top-5-binaries fingerprint was the thread entry (18 of 20 BigBasket
///   disk-write reports shared ONE fingerprint because they ran on a
///   dispatch queue, not because they were one bug), and the 20-frame cap cut
///   off the leaf — the only part that says what was actually running.
///
///   Now the whole heaviest path is walked, its orientation is decided, and
///   the stack is emitted leaf first. Truncation drops OUTER frames.
///
/// ORIENTATION, in order of trust
///   1. Where the thread-entry frame sits. A complete path always has it at
///      the OUTER end, so if exactly one end is a thread-entry binary the
///      orientation is known. Empirical, and independent of any flag.
///   2. `callStackPerThread` from the tree JSON: false → entry first.
///   3. The caller's hint (by diagnostic type) when the flag is absent.
enum OrionMetricKitStack {

    /// One flattened stack.
    struct Flat {
        /// "binaryName +0xOFFSET", innermost (leaf) frame first, at most `limit`.
        let frames: [String]
        /// The full path was longer than `limit` (outer frames were dropped).
        let truncated: Bool
        /// Frames on the full heaviest path, before the limit.
        let depth: Int
        /// binaryName → binaryUUID for the binaries in `frames`. A dSYM is
        /// matched by UUID, so without this the stack can never be symbolicated.
        let images: [String: String]
    }

    /// Thread-entry binaries: the outermost frame of every complete stack is
    /// in one of these (`start` in dyld, `thread_start`/`start_wqthread` in
    /// libsystem_pthread).
    static let threadEntryBinaries: Set<String> = [
        "dyld", "libdyld.dylib", "libsystem_pthread.dylib"
    ]

    /// Guard against a pathological tree. Real stacks are tens of frames;
    /// deep recursion can reach hundreds.
    static let maxWalkDepth = 1024

    /// - Parameters:
    ///   - data: `MXCallStackTree.jsonRepresentation()`.
    ///   - limit: frames to keep.
    ///   - entryFirstIfUnknown: orientation to assume when neither the frames
    ///     nor the flag decide it — true for hang / CPU / disk diagnostics.
    /// - Returns: nil when the tree cannot be parsed. Never throws.
    static func flatten(json data: Data, limit: Int, entryFirstIfUnknown: Bool) -> Flat? {
        // 1.2.41: JSONSerialization refuses nesting deeper than 512 levels — a
        // MetricKit stack deeper than 254 frames, i.e. most stack overflows,
        // which went out with no stack. OrionDeepJSON parses what it rejects;
        // every tree it accepts takes exactly the same path as before.
        guard !data.isEmpty,
              let parsed = (try? JSONSerialization.jsonObject(with: data)) ?? OrionDeepJSON.parse(data),
              let root = parsed as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]]
        else { return nil }

        // Prefer the thread MetricKit attributed the problem to.
        let chosen = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let rootFrames = chosen?["callStackRootFrames"] as? [[String: Any]] else { return nil }

        // Walk the WHOLE heaviest path. Following the most-sampled child at
        // each level recovers the dominant stack of an aggregated profile; a
        // per-thread (crash) tree is a single chain, so this is a no-op there.
        var path: [[String: Any]] = []
        var level = rootFrames
        while !level.isEmpty && path.count < maxWalkDepth {
            guard let frame = level.max(by: {
                (($0["sampleCount"] as? Int) ?? 0) < (($1["sampleCount"] as? Int) ?? 0)
            }) else { break }
            path.append(frame)
            level = (frame["subFrames"] as? [[String: Any]]) ?? []
        }
        guard !path.isEmpty else { return Flat(frames: [], truncated: false, depth: 0, images: [:]) }

        let entryFirst: Bool
        let firstIsEntry = isThreadEntry(path.first!)
        let lastIsEntry  = isThreadEntry(path.last!)
        if firstIsEntry != lastIsEntry {
            entryFirst = firstIsEntry
        } else if let perThread = root["callStackPerThread"] as? Bool {
            entryFirst = !perThread
        } else {
            entryFirst = entryFirstIfUnknown
        }

        let leafFirst = entryFirst ? Array(path.reversed()) : path
        let kept = Array(leafFirst.prefix(max(0, limit)))

        var images: [String: String] = [:]
        let frames = kept.map { frame -> String in
            let name = frame["binaryName"] as? String
            let uuid = frame["binaryUUID"] as? String
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            if let n = name, let u = uuid { images[n] = u }
            return label(name: name, uuid: uuid) + " +0x" + String(offset, radix: 16)
        }
        return Flat(frames: frames, truncated: leafFirst.count > kept.count,
                    depth: path.count, images: images)
    }

    /// A frame's binary label. A frame with no `binaryName` but a
    /// `binaryUUID` keeps the UUID's first 8 characters — enough to match a
    /// dSYM later — instead of collapsing into a bare `<unknown>`.
    static func label(name: String?, uuid: String?) -> String {
        if let n = name, !n.isEmpty { return n }
        if let u = uuid, u.count >= 8 { return "<unknown:" + String(u.prefix(8)) + ">" }
        return "<unknown>"
    }

    private static func isThreadEntry(_ frame: [String: Any]) -> Bool {
        guard let name = frame["binaryName"] as? String else { return false }
        return threadEntryBinaries.contains(name)
    }

    // MARK: - Fingerprint

    /// Deterministic signature from diagType + the top frames' binary names.
    ///
    /// FNV-1a rather than Swift's `hashValue`, which is seeded per-process and
    /// would produce a different fingerprint on every launch — useless for
    /// grouping across sessions or devices.
    ///
    /// SDK-05: binary NAMES only, never offsets — offsets shift on every build
    /// and every iOS point release. Offsets stay in the emitted stack for
    /// symbolication.
    ///
    /// 1.2.40: any `<unknown…>` label hashes as `<unknown>`. The UUID it may
    /// carry changes on every build of the binary, and the fingerprint must
    /// not. Crash and watchdog stacks were already leaf first, so their
    /// fingerprints are unchanged by 1.2.40; hang / CPU / disk fingerprints
    /// change once, because their top frames are now the leaf.
    ///
    /// System frames are deliberately KEPT, unlike the Android/Flutter rule:
    /// with offsets stripped, the binary *sequence* (libsystem_kernel →
    /// pthread → c → c++abi → objc = an ObjC-exception abort) is the only
    /// signal left.
    static func fingerprint(diagType: String, stack: [String], depth: Int) -> String {
        var input = diagType
        for frame in stack.prefix(depth) {
            var binary = frame.components(separatedBy: " +0x").first ?? frame
            if binary.hasPrefix("<unknown") { binary = "<unknown>" }
            input += "|" + binary
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // SDK-13: zero-padded to a fixed 16 characters.
        return String(format: "%016llx", hash)
    }
}
