//
//  OrionDeepJSON.swift
//  orion_flutter (1.2.41)
//
//  A minimal JSON parser with no nesting limit, used only when
//  JSONSerialization refuses a MetricKit call-stack tree.
//
//  WHY: JSONSerialization rejects documents nested deeper than 512 levels.
//  MXCallStackTree nests every frame inside its parent's `subFrames` array —
//  one dictionary plus one array per frame — so any stack deeper than 254
//  frames failed to parse and its diagnostic was sent with no stack at all
//  (`stackUnavailable`). Deep stacks come from runaway recursion, i.e. stack
//  overflows: the crashes where the stack matters most. It also made the
//  1,024-frame walk cap in OrionMetricKitStack unreachable. Measured: a
//  MetricKit-shaped tree of 254 frames parses, 255 does not.
//
//  Found and fixed in the native iOS SDK first (Crash/DeepJSON.swift, decision
//  D-17, 10 Oct 2026); this is the same parser, ported back. Foundation only,
//  so scripts/verify/test_metrickit_stack.sh compiles it with plain swiftc.
//
//  Iterative (an explicit container stack, no recursion), so depth costs heap,
//  not the call stack. Produces the same shapes JSONSerialization does for
//  what MetricKit emits: [String: Any], [Any], String, Int (Double when not
//  integral or out of range), Bool, NSNull.
//

import Foundation

enum OrionDeepJSON {

    /// Upper bound on nesting — a guard against hostile input, not a limit
    /// any real MetricKit tree approaches.
    static let maxDepth = 200_000

    private final class Container {
        var array: [Any]?
        var object: [String: Any]?
        var key: String?
        init(array: [Any]) { self.array = array }
        init(object: [String: Any]) { self.object = object }
        var isObject: Bool { object != nil }
        var value: Any { (object as Any?) ?? (array ?? []) }
    }

    private enum State { case value, key, afterValue, end }

    /// nil on any malformed input. Never throws, never recurses.
    static func parse(_ data: Data) -> Any? {
        let bytes = [UInt8](data)
        var i = 0
        var stack: [Container] = []
        var root: Any?
        var state = State.value

        func skipWS() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 {
                i += 1
            }
        }

        /// Places a finished value and moves to the next state.
        func attach(_ v: Any) {
            guard let top = stack.last else {
                root = v
                state = .end
                return
            }
            if top.isObject {
                if let k = top.key { top.object?[k] = v }
                top.key = nil
            } else {
                top.array?.append(v)
            }
            state = .afterValue
        }

        while true {
            skipWS()
            switch state {
            case .end:
                return i == bytes.count ? root : nil

            case .value:
                guard i < bytes.count else { return nil }
                switch bytes[i] {
                case UInt8(ascii: "{"):
                    i += 1
                    guard stack.count < maxDepth else { return nil }
                    stack.append(Container(object: [:]))
                    skipWS()
                    if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                        i += 1
                        attach(stack.removeLast().value)
                    } else {
                        state = .key
                    }
                case UInt8(ascii: "["):
                    i += 1
                    guard stack.count < maxDepth else { return nil }
                    stack.append(Container(array: []))
                    skipWS()
                    if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                        i += 1
                        attach(stack.removeLast().value)
                    }
                    // else: stay in .value for the first element
                case UInt8(ascii: "\""):
                    guard let s = parseString(bytes, &i) else { return nil }
                    attach(s)
                case UInt8(ascii: "t"):
                    guard matchLiteral(bytes, &i, "true") else { return nil }
                    attach(true)
                case UInt8(ascii: "f"):
                    guard matchLiteral(bytes, &i, "false") else { return nil }
                    attach(false)
                case UInt8(ascii: "n"):
                    guard matchLiteral(bytes, &i, "null") else { return nil }
                    attach(NSNull())
                default:
                    guard let n = parseNumber(bytes, &i) else { return nil }
                    attach(n)
                }

            case .key:
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\""),
                      let k = parseString(bytes, &i) else { return nil }
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                stack.last?.key = k
                state = .value

            case .afterValue:
                guard i < bytes.count, let top = stack.last else { return nil }
                let c = bytes[i]
                i += 1
                if c == UInt8(ascii: ",") {
                    state = top.isObject ? .key : .value
                } else if (c == UInt8(ascii: "}") && top.isObject) || (c == UInt8(ascii: "]") && !top.isObject) {
                    attach(stack.removeLast().value)
                } else {
                    return nil
                }
            }
        }
    }

    private static func matchLiteral(_ b: [UInt8], _ i: inout Int, _ lit: String) -> Bool {
        let u = Array(lit.utf8)
        guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { return false }
        i += u.count
        return true
    }

    private static func parseNumber(_ b: [UInt8], _ i: inout Int) -> Any? {
        let start = i
        var integral = true
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                i += 1
            } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                integral = false
                i += 1
            } else {
                break
            }
        }
        guard i > start, let text = String(bytes: b[start..<i], encoding: .ascii) else { return nil }
        if integral, let n = Int(text) { return n }
        return Double(text)
    }

    /// `i` is on the opening quote; leaves it after the closing one.
    private static func parseString(_ b: [UInt8], _ i: inout Int) -> String? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            i += 1
            if c == UInt8(ascii: "\"") {
                return String(decoding: out, as: UTF8.self)
            }
            guard c == UInt8(ascii: "\\") else {
                guard c >= 0x20 else { return nil }      // raw control characters are invalid
                out.append(c)
                continue
            }
            guard i < b.count else { return nil }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard var scalar = hex4(b, &i) else { return nil }
                // Surrogate pair → one scalar.
                if (0xD800...0xDBFF).contains(scalar) {
                    guard i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") else { return nil }
                    i += 2
                    guard let low = hex4(b, &i), (0xDC00...0xDFFF).contains(low) else { return nil }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let u = Unicode.Scalar(scalar) else { return nil }
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default:
                return nil
            }
        }
        return nil
    }

    private static func hex4(_ b: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= b.count, let s = String(bytes: b[i..<(i + 4)], encoding: .ascii),
              let v = UInt32(s, radix: 16) else { return nil }
        i += 4
        return v
    }
}
