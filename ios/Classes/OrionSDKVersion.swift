//
//  OrionSDKVersion.swift
//  orion_flutter
//
//  The Orion SDK version this build reports as `libVer`.
//
//  Bumped with the podspec by scripts/release/lib/bump_swift_version.py in
//  release phase 1. verify_ios_release.sh fails the release if the two differ.
//  Keep this a plain string literal: reading it must cost nothing, on any
//  thread. See OrionConfig.sdkVersion for why it is not read from a Bundle.
//

enum OrionSDKVersion {
    static let current = "1.2.42"
}
