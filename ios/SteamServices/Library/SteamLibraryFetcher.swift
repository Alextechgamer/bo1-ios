// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Fetches the owned games list via Steam's product info service (PICS).
@MainActor
class SteamLibraryFetcher {
    private let session: SteamCMSession

    init(session: SteamCMSession) {
        self.session = session
    }

    // MARK: - Fetch Owned Games

    /// Fetches the account's package IDs from the license list, resolves them
    /// to app IDs and returns the playable apps' metadata.
    func fetchOwnedApps() async throws -> [SteamAppInfo] {
        let appIDs = try await ownedAppIDs()

        // Step 4: PICS access tokens for the apps.
        let appTokens = try await fetchPICSAccessTokens(appIDs: Array(appIDs))

        // Step 5: app info (name, depots, platform support, ...).
        let appInfos = try await fetchAppInfo(appIDs: Array(appIDs), tokens: appTokens)
        SteamLog.trace("Got info for \(appInfos.count) apps")

        // Playable types only: games, demos and applications. This leaves out
        // DLC, soundtracks and tools (redistributables, runtimes, SDKs, servers).
        let games = appInfos.filter { $0.type.isPlayable }
        SteamLog.trace("\(games.count) of \(appInfos.count) apps are playable (game/demo/application)")
        return games
    }

    /// All app IDs in the signed-in account's packages, including DLC. This
    /// deliberately precedes `fetchOwnedApps`' playable-type filter.
    func ownedAppIDs() async throws -> Set<UInt32> {
        try Task.checkCancellation()
        try await session.ensureConnected()
        let packageIDs = try await fetchLicenseList()
        let tokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)
        let apps = try await fetchAppIDsFromPackages(packageIDs: packageIDs, tokens: tokens)
        try Task.checkCancellation()
        return apps
    }

    /// Depot IDs included in the account's licenses, from the same package
    /// info the library uses (`depotids`). The installer consults it only when
    /// Steam refuses a depot key, to leave out a depot the account does not
    /// own (another edition, extra content). Cached per session.
    private var ownedDepotCache: (account: UInt64, revision: UInt64, depots: Set<UInt32>)?
    func ownedDepotIDs() async throws -> Set<UInt32> {
        try Task.checkCancellation()
        try await session.ensureConnected()
        let account = session.steamID, revision = SteamSignIn.revision
        if let cached = ownedDepotCache, cached.account == account, cached.revision == revision {
            return cached.depots
        }
        let packageIDs = try await fetchLicenseList()
        let tokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)
        var depots = Set<UInt32>()
        for start in stride(from: 0, to: packageIDs.count, by: 50) {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = packageIDs[start..<min(start + 50, packageIDs.count)].map {
                CMsgClientPICSProductInfoRequest.PackageInfo(packageid: $0, accessToken: tokens[$0] ?? 0)
            }
            let responses = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest,
                                                              body: request.serialize(), timeout: 30)
            for response in responses {
                let pics = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in pics.packages where packageIDs.contains(pkg.packageid) { depots.formUnion(try VDFParser.parsePackageIDs(key: "depotids", from: pkg.buffer)) }
            }
        }
        try Task.checkCancellation()
        guard session.steamID == account, SteamSignIn.revision == revision else {
            throw SteamError.disconnected
        }
        ownedDepotCache = (account, revision, depots)
        return depots
    }

    /// Fetches PICS info for a single app on demand: one token round trip and
    /// one product-info round trip, no license list. Connects the session if it
    /// sits idle-disconnected.
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? {
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: [appID])
        return try await fetchAppInfo(appIDs: [appID], tokens: tokens).first
    }

    // MARK: - Install metadata

    /// The app's metadata for an install, with the content metadata of the
    /// apps it shares depots with resolved. This never supplies depot keys or
    /// grants access: every later content request still goes to Valve.
    func fetchInstallInfo(appID: UInt32, language: String = "english",
                          includeDLC: Bool = false) async throws -> SteamAppInfo? {
        try Task.checkCancellation()
        guard var app = try await fetchAppInfo(appID: appID) else { return nil }
        try Task.checkCancellation()
        var owners: [UInt32: SteamAppInfo] = [appID: app]
        var visited: Set<UInt32> = [appID], references = Set<String>()
        func eligible(_ d: SteamAppInfo.DepotInfo) -> Bool {
            !d.isSharedInstall && (includeDLC || d.dlcAppID == nil) && d.supports(os: "windows") &&
                !d.lowViolence && (d.language.isEmpty || d.language.caseInsensitiveCompare(language) == .orderedSame)
        }
        var pending = app.depots.filter { eligible($0) && $0.fromApp != nil }
            .map { ($0.fromApp!, $0.depotID) }
        while let (id, depotID) = pending.popLast() {
            try Task.checkCancellation()
            if !references.insert("\(id):\(depotID)").inserted { continue }
            guard references.count <= 1024 else { throw SteamFileError.invalid("Too many shared content references.") }
            if visited.insert(id).inserted {
                guard visited.count <= 32 else { throw SteamFileError.invalid("Too many shared content dependencies.") }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let source = owners[id]?.depots.first(where: { $0.depotID == depotID }),
               let next = source.fromApp {
                pending.append((next, depotID))
            }
        }
        // A bounded fixed point handles nested sharing without recursion or cycles.
        try Task.checkCancellation()
        for _ in 0..<owners.count {
            var changed = 0
            for id in owners.keys.sorted() {
                var owner = owners[id]!
                changed += owner.inheritDepots(from: owners)
                owners[id] = owner
            }
            if changed == 0 { break }
        }
        let resolved = app.inheritDepots(from: owners)
        let missing = app.depots.filter { eligible($0) && $0.fromApp != nil && $0.publicManifestID == nil }
        SteamLog.event("[steam-shared] app=\(appID) owners=\(visited.count - 1) resolved=\(resolved) missing=\(missing.count)")
        guard missing.isEmpty else { throw SteamFileError.invalid("Steam did not provide required shared content metadata. Refresh and retry the download.") }
        // The direct owner of each selected shared depot, for its install
        // record. Metadata only; Valve still decides access and launch readiness.
        for id in Set(app.depots.filter(eligible).compactMap(\.fromApp)).subtracting([appID]).sorted() {
            try Task.checkCancellation()
            if owners[id] == nil {
                guard owners.count <= 64 else { break }
                owners[id] = try await fetchAppInfo(appID: id)
            }
            if let owner = owners[id] {
                app.sharedOwners[id] = .init(name: owner.name, installDir: owner.installDir, buildID: owner.buildID)
            }
        }
        return app
    }

    // MARK: - License List

    private func fetchLicenseList() async throws -> [UInt32] {
        try await session.awaitLicenseList(timeout: 15)
    }

    // MARK: - PICS Access Tokens

    private func fetchPICSAccessTokens(appIDs: [UInt32] = [], packageIDs: [UInt32] = []) async throws -> [UInt32: UInt64] {
        var request = CMsgClientPICSAccessTokenRequest()
        request.appids = appIDs
        request.packageids = packageIDs

        let response = try await session.sendAndWait(
            eMsg: .clientPICSAccessTokenRequest,
            body: request.serialize(),
            responseEMsg: .clientPICSAccessTokenResponse,
            timeout: 30
        )

        let tokenResponse = try CMsgClientPICSAccessTokenResponse.deserialize(from: response.body)

        var tokens: [UInt32: UInt64] = [:]
        for appToken in tokenResponse.appAccessTokens {
            tokens[appToken.appid] = appToken.accessToken
        }
        for pkgToken in tokenResponse.packageAccessTokens {
            tokens[pkgToken.packageid] = pkgToken.accessToken
        }

        return tokens
    }

    // MARK: - Package Info → App IDs

    private func fetchAppIDsFromPackages(packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var allAppIDs = Set<UInt32>()

        // Package info requests in batches of 50.
        let batches = stride(from: 0, to: packageIDs.count, by: 50).map {
            Array(packageIDs[$0..<min($0 + 50, packageIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { pkgID in
                CMsgClientPICSProductInfoRequest.PackageInfo(
                    packageid: pkgID,
                    accessToken: tokens[pkgID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in picsResponse.packages where batch.contains(pkg.packageid) {
                    allAppIDs.formUnion(try VDFParser.parsePackageAppIDs(from: pkg.buffer))
                }
            }
        }

        return allAppIDs
    }

    // MARK: - App Info

    private func fetchAppInfo(appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamAppInfo] {
        var allApps: [SteamAppInfo] = []

        // App info requests in batches of 50.
        let batches = stride(from: 0, to: appIDs.count, by: 50).map {
            Array(appIDs[$0..<min($0 + 50, appIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map { appID in
                CMsgClientPICSProductInfoRequest.AppInfo(
                    appid: appID,
                    accessToken: tokens[appID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for app in picsResponse.apps {
                    if let info = SteamAppInfo.parse(appID: app.appid, from: app.buffer) {
                        allApps.append(info)
                    }
                }
            }
        }

        return allApps
    }
}

// MARK: - Simple VDF Binary Parser

/// Parses Valve Data Format (binary) used in PICS responses
enum VDFParser {
    // VDF binary types
    private static let typeNone: UInt8 = 0x00
    private static let typeString: UInt8 = 0x01
    private static let typeInt32: UInt8 = 0x02
    private static let typeEnd: UInt8 = 0x08

    /// Parse a text-format VDF / KeyValues blob into a nested dictionary.
    /// Steam PICS sends *app* product info in this text format (`"key" "value"`
    /// pairs and `"key" { ... }` sections) — package info uses the binary
    /// format. Leaf values are always `String`. Steam escapes `"` and `\` inside
    /// a quoted string (for example a launch argument `/Name=\"Two Words\"`); read
    /// verbatim, such a string ends early and every later section, the depots
    /// among them, is lost.
    static func parseTextVDF(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func skipWhitespaceAndComments() {
            while i < n {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                    while i < n && scalars[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func nextToken() -> String? {
            skipWhitespaceAndComments()
            guard i < n else { return nil }
            let c = scalars[i]
            if c == "{" || c == "}" {
                i += 1
                return String(c)
            }
            var s = ""
            if c == "\"" {
                i += 1
                while i < n && scalars[i] != "\"" {
                    // \" and \\ are escapes; any other backslash is literal (paths).
                    if scalars[i] == "\\", i + 1 < n, scalars[i + 1] == "\"" || scalars[i + 1] == "\\" {
                        s.unicodeScalars.append(scalars[i + 1])
                        i += 2
                        continue
                    }
                    s.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1 // closing quote
                return s
            }
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                    || ch == "{" || ch == "}" || ch == "\"" { break }
                s.unicodeScalars.append(ch)
                i += 1
            }
            return s
        }

        func parseSection() -> [String: Any] {
            var dict: [String: Any] = [:]
            while let key = nextToken() {
                if key == "}" { break }
                if key == "{" { continue }
                guard let value = nextToken() else { break }
                if value == "{" {
                    dict[key] = parseSection()
                } else if value == "}" {
                    break
                } else {
                    dict[key] = value
                }
            }
            return dict
        }

        return parseSection()
    }

    /// Package PICS buffers have a uint32 format=1 header followed by binary
    /// KeyValues, as consumed by SteamKit's SteamApps/PICSProductInfo. Read
    /// structure, never a byte-substring match that can select an unrelated
    /// string's contents as an entitlement list.
    static func parsePackageAppIDs(from data: Data) throws -> [UInt32] {
        try parsePackageIDs(key: "appids", from: data)
    }

    static func parsePackageIDs(key searchKey: String, from data: Data) throws -> [UInt32] {
        let data = Data(data)
        guard searchKey == "appids" || searchKey == "depotids", data.count >= 8,
              data.count <= 16 * 1024 * 1024,
              data.prefix(4).elementsEqual([1, 0, 0, 0]) else {
            throw SteamError.protobufError("Unsupported package metadata format")
        }
        var offset = 4, nodes = 0, matchingSections = 0
        var ids: [UInt32] = []
        func invalid() -> SteamError { .protobufError("Malformed package metadata") }
        func string() throws -> String {
            let start = offset
            while offset < data.count && data[offset] != 0 {
                offset += 1
                guard offset - start <= 64 * 1024 else { throw invalid() }
            }
            guard offset < data.count, let value = String(data: data[start..<offset], encoding: .utf8) else {
                throw invalid()
            }
            offset += 1
            return value
        }
        func uint32() throws -> UInt32 {
            guard offset <= data.count - 4 else { throw invalid() }
            defer { offset += 4 }
            return data[offset..<(offset + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        func skip(_ bytes: Int) throws {
            guard offset <= data.count - bytes else { throw invalid() }
            offset += bytes
        }
        func section(_ path: [String]) throws {
            guard path.count <= 32 else { throw invalid() }
            while offset < data.count {
                let type = data[offset]; offset += 1
                if type == 8 || type == 11 { return }
                nodes += 1
                guard nodes <= 250_000 else { throw invalid() }
                let name = try string()
                let isID = path.count == 2 && path[1] == searchKey
                if isID && type != 1 && type != 2 { throw invalid() }
                switch type {
                case 0:
                    if path.count == 1 && name == searchKey {
                        matchingSections += 1
                        guard matchingSections == 1 else { throw invalid() }
                    }
                    try section(path + [name])
                case 1:
                    let value = try string()
                    if isID {
                        guard UInt32(name) != nil, let id = UInt32(value), id != 0 else { throw invalid() }
                        ids.append(id)
                    }
                case 2:
                    let value = try uint32()
                    if isID {
                        guard UInt32(name) != nil, value != 0 else { throw invalid() }
                        ids.append(value)
                    }
                case 3, 4, 6: try skip(4)
                case 7, 10: try skip(8)
                default: throw invalid() // Includes unsupported wide strings.
                }
            }
            throw invalid() // Every object must have an explicit end marker.
        }
        guard data[offset] == 0 else { throw invalid() }
        offset += 1
        _ = try string() // Root name is the package's numeric ID.
        try section(["root"])
        guard offset < data.count, data[offset] == 8 || data[offset] == 11 else { throw invalid() }
        offset += 1
        guard offset == data.count else { throw invalid() }
        return ids
    }
}
