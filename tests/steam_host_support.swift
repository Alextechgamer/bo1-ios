// SPDX-License-Identifier: GPL-3.0-or-later
// Host-test boundary only. Authentication/UI/Keychain are deliberately absent.
// The actual parser, metadata, storage, manifest and content implementations
// compile unchanged against these inert logging/credential-generation names.
import Foundation

enum SteamSignIn {
    static let revision: UInt64 = 0
}

enum SteamLog {
    static func trace(_ message: @autoclosure () -> String) {}
    static func event(_ message: String) {}
}
