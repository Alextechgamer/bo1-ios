// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Substantially
// rewritten by 125hz for the owned library and downloads (docs/STEAM_LIBRARY.md).
//
// BO2 adaptation: installs into the app's own game folder instead of a Steam
// library, writes no Steam install record and keeps no manifest cache.
// BO1 changes: explicit depot selection, contained staging, verified resume,
// chunk SHA1 validation and cancellation propagation. See SteamAuth/UPSTREAM.md.

import Foundation
import zlib
import CommonCrypto

/// Progress for one application install, across all of its depots.
struct SteamDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, downloading, finishing }
    var phase: Phase = .preparing
    /// Compressed bytes to fetch for the whole install (all selected depots).
    var totalBytes: UInt64 = 0
    /// Compressed bytes already on disk, including chunks resumed from a
    /// previous attempt.
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

/// Only regular files named by the selected, validated current manifests.
/// A coordinator can publish these from private staging without copying stale
/// files left by an earlier selection or interrupted manifest revision.
struct SteamInstallResult: Sendable {
    let relativeFiles: [String]
}

/// Orchestrates downloading an owned application's Windows depots from the
/// Steam content network into the app's game folder.
///
/// Follows Steam's content protocol: the account's depot key and the
/// manifest request code come from the CM connection, which issues them only
/// to an account that owns the depot; manifests and chunks come from content
/// servers over HTTPS. Nothing here alters the downloaded files.
///
/// Behaviour:
/// - All manifests are fetched first, so progress covers the whole install.
/// - Completed chunks are journaled per depot manifest; a cancelled, failed or
///   interrupted install resumes without re-fetching them.
/// - Files are sized to their manifest length, so an update that shrinks a
///   file cannot leave stale trailing bytes.
/// - Chunk writes happen on the download tasks with pwrite, never on the
///   main actor; a dedicated URLSession keeps chunks out of the URL cache.
/// - Manifest paths are validated to stay inside the install folder, and
///   directory names are folded case-insensitively (Windows semantics on a
///   case-sensitive iOS volume).
/// - Each chunk retries on other content servers before the install fails.
@MainActor
final class DepotDownloader {
    private let session: SteamCMSession
    private var depotKeys: [UInt32: Data] = [:]
    private var cdnAuthTokens: [String: String] = [:]  // "depot|host" -> "?auth=…" fragment
    private let maxConcurrentChunks = 8
    private let attemptsPerChunk = 5
    private let hostPoolSize = 6

    private nonisolated static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    /// Replaces the content server directory (host tests only): the servers
    /// to fetch from, as `https://host` or `http://host:port` URLs.
    var contentHosts: ((_ appID: UInt32) async throws -> [String])?

    init(session: SteamCMSession) {
        self.session = session
    }

    // MARK: - Public API

    /// Download an app into `installURL`, journaling finished chunks under
    /// `journalRoot/<appid>`. Throws CancellationError when the calling task
    /// is cancelled; completed chunks stay journaled.
    @discardableResult
    func install(_ app: SteamAppInfo, into installURL: URL, journals journalRoot: URL,
                 selectedDepotIDs: Set<UInt32>? = nil,
                 reusing existingURL: URL? = nil,
                 ownedDepots: @escaping () async -> Set<UInt32>? = { nil },
                 progress report: @escaping (SteamDownloadProgress) -> Void) async throws -> SteamInstallResult {
        try Task.checkCancellation()
        let depots: [SteamAppInfo.DepotInfo]
        if let selectedDepotIDs {
            depots = app.depots.filter { selectedDepotIDs.contains($0.depotID) }
                .sorted { $0.depotID < $1.depotID }
            guard Set(depots.map(\.depotID)) == selectedDepotIDs,
                  depots.count == selectedDepotIDs.count,
                  depots.allSatisfy({ !$0.isSharedInstall && $0.supports(os: "windows") &&
                      !$0.lowViolence && $0.publicManifestID != nil }) else {
                throw SteamFileError.invalid("A selected depot has no eligible Windows public manifest. Refresh Steam metadata.")
            }
        } else {
            depots = app.installDepots()
        }
        guard !depots.isEmpty else { throw SteamError.depotNotFound(app.appID) }
        // Before the key requests, so a refused depot still has its selection logged.
        SteamLog.event("[steam-depot] selection app=\(app.appID) build=\(app.buildID) depots=\(depots.map { String($0.depotID) }.joined(separator: ","))")

        // Cached depot keys and edge tokens belong to one authenticated account.
        // Reauthorization is cheap compared with accidentally retaining access
        // across an account switch on a reused downloader instance.
        depotKeys.removeAll()
        cdnAuthTokens.removeAll()

        let journalDir = journalRoot.appendingPathComponent("\(app.appID)", isDirectory: true)
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        var state = SteamDownloadProgress()
        report(state)

        let hosts: [String]
        if let provider = contentHosts { hosts = try await provider(app.appID) } else { hosts = try await contentServers(appID: app.appID) }
        guard !hosts.isEmpty else { throw SteamError.chunkDownloadFailed("No content servers are available.") }

        // 1. Keys, manifests and per-host authorization for every depot.
        let health = ContentHostHealth()
        let pool = Array(hosts.prefix(hostPoolSize))
        var plans: [DepotPlan] = []
        var licenseSkipped: [UInt32] = []
        for depot in depots {
            try Task.checkCancellation()
            guard let gid = depot.publicManifestID else { continue }
            let key: Data
            do {
                key = try await depotKey(depotID: depot.depotID, appID: app.appID)
            } catch SteamError.depotKeyNotFound(let refused) {
                // A depot Steam refuses AND the account's licenses do not
                // include is content this account does not own (another
                // edition, extra content): it is left out. Any other refusal
                // still fails.
                if selectedDepotIDs == nil, let owned = await ownedDepots(), !owned.isEmpty, !owned.contains(refused) {
                    licenseSkipped.append(refused)
                    continue
                }
                throw SteamError.depotKeyNotFound(refused)
            }
            let contentAppID = !app.freeToDownload ? (depot.fromApp ?? app.appID) : app.appID
            let manifest = try await fetchManifest(depotID: depot.depotID, appID: contentAppID,
                                                   manifestGID: gid, key: key, hosts: hosts)
            var auth: [String: String] = [:]
            for host in pool {
                auth[host] = await cdnAuthFragment(depotID: depot.depotID, appID: contentAppID, host: host)
            }
            plans.append(DepotPlan(depotID: depot.depotID, manifestGID: gid, key: key, manifest: manifest,
                                   hosts: pool, auth: auth,
                                   declaredSize: depot.publicSizeBytes, health: health))
        }
        if !licenseSkipped.isEmpty {
            SteamLog.event("[steam-depot] license app=\(app.appID) skipped=\(licenseSkipped.map(String.init).joined(separator: ",")) kept=\(plans.map { String($0.depotID) }.joined(separator: ","))")
        }
        guard !plans.isEmpty else {
            if let refused = licenseSkipped.first { throw SteamError.depotKeyNotFound(refused) }
            throw SteamError.depotNotFound(app.appID)
        }

        // 2. Prepare files and load journals off the main actor.
        let downloadPlans = plans
        let preparation = Task.detached(priority: .userInitiated) {
            try Self.prepare(plans: downloadPlans, installURL: installURL, journalDir: journalDir,
                             existingURL: existingURL)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        state.totalBytes = prepared.totalBytes
        state.doneBytes = prepared.doneBytes
        state.phase = .downloading
        report(state)
        SteamLog.event("[steam-depot] install begin app=\(app.appID) depots=\(plans.count) files=\(prepared.fileCount) resume=\(prepared.doneBytes > 0 ? 1 : 0)")

        let remaining = prepared.remainingUncompressed
        if remaining > 0 {
            let values = try? installURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? Int64.max))
            if available < remaining { throw SteamError.insufficientDiskSpace(needed: remaining, available: available) }
        }

        // 3. Chunks.
        let started = Date()
        let resumedBytes = state.doneBytes
        var lastReport = Date.distantPast
        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            let journal = try JournalWriter(url: prepared.journals[index])
            defer { try? journal.close() }
            let work = prepared.pending[index]
            let paths = prepared.paths[index]
            let existing = prepared.existing[index]
            let maximum = maxConcurrentChunks, attempts = attemptsPerChunk
            try await withThrowingTaskGroup(of: (UInt64, UInt64).self) { group in
                var next = 0
                func enqueue() {
                    guard next < work.count else { return }
                    let item = work[next]; next += 1
                    let chunk = plan.manifest.files[item.file].chunks[item.chunk]
                    let path = paths[item.file]
                    let verify = existing[item.file]
                    group.addTask {
                        try Task.checkCancellation()
                        if verify, Self.verifiedChunk(chunk, root: prepared.root, path: path) != nil {
                            return (item.key, UInt64(chunk.compressedSize))
                        }
                        if let reuse = prepared.reuse,
                           let bytes = Self.verifiedChunk(chunk, root: reuse, path: path) {
                            try Task.checkCancellation()
                            try Self.write(bytes, root: prepared.root, to: path, offset: chunk.offset)
                            return (item.key, UInt64(chunk.compressedSize))
                        }
                        try await Self.fetchChunk(chunk, plan: plan, root: prepared.root, path: path,
                                                  attempts: attempts, seed: item.file &+ item.chunk)
                        return (item.key, UInt64(chunk.compressedSize))
                    }
                }
                for _ in 0..<min(maximum, work.count) { enqueue() }
                for try await (key, bytes) in group {
                    try Task.checkCancellation()
                    try journal.append(key)
                    state.doneBytes += bytes
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        let elapsed = now.timeIntervalSince(started)
                        if elapsed > 1 { state.bytesPerSecond = Double(state.doneBytes - resumedBytes) / elapsed }
                        report(state)
                    }
                    enqueue()
                }
            }
            try journal.close()
        }

        // 4. No Steam install record: the game folder belongs to this app alone.
        try Task.checkCancellation()
        state.phase = .finishing
        report(state)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: journalDir)
        SteamLog.event("[steam-depot] install complete app=\(app.appID) bytes=\(prepared.totalUncompressed) seconds=\(Int(Date().timeIntervalSince(started)))")
        return SteamInstallResult(relativeFiles: prepared.relativeFiles.sorted())
    }

    /// Whether a previous attempt left resumable progress for this app.
    static func hasPartialDownload(appID: UInt32, journals journalRoot: URL) -> Bool {
        let dir = journalRoot.appendingPathComponent("\(appID)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".journal") }
    }

    // MARK: - Plan

    struct DepotPlan: Sendable {
        let depotID: UInt32
        let manifestGID: UInt64
        let key: Data
        let manifest: DepotManifest
        let hosts: [String]
        let auth: [String: String]
        let declaredSize: UInt64
        let health: ContentHostHealth
    }

    struct WorkItem: Sendable {
        let file: Int
        let chunk: Int
        var key: UInt64 { UInt64(file) << 32 | UInt64(chunk) }
    }

    struct Prepared: Sendable {
        let root: SteamContentFileRoot
        let reuse: SteamContentFileRoot?
        var relativeFiles: Set<String> = []
        var paths: [[String]] = []       // per depot, per file: contained relative path ("" = skipped)
        var existing: [[Bool]] = []      // per depot, per file: had content before this install
        var pending: [[WorkItem]] = []   // per depot: chunks still to fetch
        var journals: [URL] = []
        var totalBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        var totalUncompressed: UInt64 = 0
        var remainingUncompressed: UInt64 = 0
        var fileCount = 0
    }

    nonisolated static func prepare(plans: [DepotPlan], installURL: URL, journalDir: URL,
                                             existingURL: URL?) throws -> Prepared {
        let root = try SteamContentFileRoot(url: installURL)
        // Reuse is optional: a missing source just causes a normal download.
        // A present symlink/non-directory root is never followed by the helper.
        let reuse = existingURL.flatMap { try? SteamContentFileRoot(url: $0) }
        var result = Prepared(root: root, reuse: reuse)
        var folded: [String: String] = [:]
        var filesByPath: [String: (path: String, file: DepotManifest.FileEntry)] = [:]
        // Only the exact manifest's journal is consulted. Older journals are
        // harmless and disappear after a fully completed app install.
        for plan in plans {
            try Task.checkCancellation()
            let journalURL = journalDir.appendingPathComponent("depot_\(plan.depotID)_\(plan.manifestGID).journal")
            let done = JournalWriter.load(journalURL)
            var paths: [String] = []
            var existing: [Bool] = []
            var pending: [WorkItem] = []
            paths.reserveCapacity(plan.manifest.files.count)
            for (fileIndex, file) in plan.manifest.files.enumerated() {
                try Task.checkCancellation()
                // Windows game files do not require Unix symbolic links.
                if file.flags & 0x200 != 0 {
                    paths.append(""); existing.append(false); continue
                }
                guard var relative = SteamInstallFiles.safeRelativePath(file.filename, folded: &folded,
                                                                          isDirectory: file.isDirectory) else {
                    throw SteamFileError.invalid("Steam supplied a path outside the supported game-file layout.")
                }
                if file.isDirectory {
                    try root.makeDirectory(relative)
                    paths.append(""); existing.append(false); continue
                }
                try validateFile(file)
                let foldedPath = relative.lowercased()
                if let previous = filesByPath[foldedPath] {
                    guard previous.file.size == file.size, previous.file.flags == file.flags,
                          previous.file.chunks == file.chunks else {
                        throw SteamFileError.invalid("Selected depots contain conflicting versions of a game file. Install them separately.")
                    }
                    relative = previous.path
                } else {
                    filesByPath[foldedPath] = (relative, file)
                }
                let before = try sizeFile(root: root, path: relative, to: file.size)
                let hadContent = before.st_size > 0
                existing.append(hadContent)
                paths.append(relative)
                result.relativeFiles.insert(relative)
                result.fileCount += 1
                try add(file.size, to: &result.totalUncompressed)
                for (chunkIndex, chunk) in file.chunks.enumerated() {
                    try Task.checkCancellation()
                    let item = WorkItem(file: fileIndex, chunk: chunkIndex)
                    try add(UInt64(chunk.compressedSize), to: &result.totalBytes)
                    // A journal records completed writes, not their continued
                    // existence. Deletion, truncation or edits must not produce
                    // a false successful resume.
                    if done.contains(item.key), hadContent,
                       verifiedChunk(chunk, root: root, path: relative) != nil {
                        try add(UInt64(chunk.compressedSize), to: &result.doneBytes)
                    } else {
                        pending.append(item)
                    }
                }
                let allocated = UInt64(max(0, before.st_blocks)) * 512
                try add(file.size > allocated ? file.size - allocated : 0,
                        to: &result.remainingUncompressed)
            }
            result.paths.append(paths)
            result.existing.append(existing)
            result.pending.append(pending)
            result.journals.append(journalURL)
        }
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func add(_ value: UInt64, to total: inout UInt64) throws {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw SteamFileError.invalid("Steam supplied an oversized manifest.") }
        total = sum
    }

    nonisolated static func validateFile(_ file: DepotManifest.FileEntry) throws {
        guard file.size <= UInt64(Int64.max) else { throw SteamFileError.invalid("Steam supplied an oversized file.") }
        var end: UInt64 = 0
        for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            guard chunk.sha.count == Int(CC_SHA1_DIGEST_LENGTH), chunk.compressedSize > 0,
                  Int(chunk.compressedSize) <= ContentDecryptor.maximumChunkBytes,
                  chunk.uncompressedSize > 0, Int(chunk.uncompressedSize) <= ContentDecryptor.maximumChunkBytes,
                  chunk.offset == end, chunk.offset <= file.size,
                  UInt64(chunk.uncompressedSize) <= file.size - chunk.offset else {
                throw SteamFileError.invalid("Steam supplied an invalid chunk range or checksum.")
            }
            end += UInt64(chunk.uncompressedSize)
        }
        guard end == file.size else { throw SteamFileError.invalid("Steam's manifest does not cover a complete game file.") }
    }

    /// Resize only the staging file, opened through no-follow descriptors.
    private nonisolated static func sizeFile(root: SteamContentFileRoot, path: String, to size: UInt64) throws -> stat {
        try Task.checkCancellation()
        let fd = try root.openFile(path, writing: true, create: true)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SteamError.chunkDownloadFailed("Cannot inspect a game file (errno \(errno)).") }
        if UInt64(info.st_size) == size { return info }
        try Task.checkCancellation()
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot size a game file (errno \(errno)).")
        }
        return info
    }

    // MARK: - Chunks

    /// A chunk's ID is the SHA-1 of its uncompressed bytes. When a file
    /// already had content (an update, or a resume without a journal), bytes
    /// that already match are kept instead of downloaded again.
    nonisolated static func verifiedChunk(_ chunk: DepotManifest.ChunkEntry,
                                                    root: SteamContentFileRoot, path: String) -> Data? {
        let length = Int(chunk.uncompressedSize)
        guard !Task.isCancelled, chunk.sha.count == Int(CC_SHA1_DIGEST_LENGTH), length > 0,
              length <= ContentDecryptor.maximumChunkBytes,
              let fd = try? root.openFile(path, writing: false, create: false) else { return nil }
        defer { close(fd) }
        var bytes = Data(count: length)
        let count = bytes.withUnsafeMutableBytes { raw -> Int in
            var copied = 0
            while copied < length {
                guard !Task.isCancelled else { return -1 }
                let n = pread(fd, raw.baseAddress! + copied, length - copied, off_t(chunk.offset) + off_t(copied))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return -1 }
                copied += n
            }
            return copied
        }
        guard count == length, matchesSHA(bytes, expected: chunk.sha) else { return nil }
        return bytes
    }

    nonisolated static func matchesSHA(_ data: Data, expected: Data) -> Bool {
        guard expected.count == Int(CC_SHA1_DIGEST_LENGTH), data.count <= Int(UInt32.max) else { return false }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest) == expected
    }

    private nonisolated static func fetchChunk(_ chunk: DepotManifest.ChunkEntry, plan: DepotPlan,
                                               root: SteamContentFileRoot, path: String, attempts: Int, seed: Int) async throws {
        var lastError: Error = SteamError.chunkDownloadFailed("No content server responded.")
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            // Healthy servers first, starting from a per-chunk offset.
            let order = plan.health.order(plan.hosts, seed: seed)
            let host = order[attempt % order.count]
            let url = "\(host)/depot/\(plan.depotID)/chunk/\(chunk.shaHex)\(plan.auth[host] ?? "")"
            do {
                let encrypted = try await download(url)
                try Task.checkCancellation()
                let data = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: plan.key,
                                                             expectedCRC: chunk.crc,
                                                             expectedSize: Int(chunk.uncompressedSize))
                guard data.count == Int(chunk.uncompressedSize), matchesSHA(data, expected: chunk.sha) else {
                    throw SteamError.checksumMismatch
                }
                try Task.checkCancellation()
                try write(data, root: root, to: path, offset: chunk.offset)
                plan.health.recordSuccess(host)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                plan.health.recordFailure(host, reason: failureReason(error))
                SteamLog.trace("chunk attempt \(attempt + 1) failed: \(failureReason(error))")
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000) }
            }
        }
        throw lastError
    }

    private nonisolated static func failureReason(_ error: Error) -> String {
        if let url = error as? URLError { return "url\(url.code.rawValue)" }
        if case SteamError.chunkDecodeFailed(let format) = error { return "decode-\(format)" }
        if case SteamError.checksumMismatch = error { return "checksum" }
        return "other"
    }

    private nonisolated static func write(_ data: Data, root: SteamContentFileRoot, to path: String, offset: UInt64) throws {
        try Task.checkCancellation()
        let fd = try root.openFile(path, writing: true, create: false)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, offset <= UInt64(info.st_size),
              UInt64(data.count) <= UInt64(info.st_size) - offset else {
            throw SteamFileError.invalid("A chunk write would exceed its staged game file.")
        }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                try Task.checkCancellation()
                let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw SteamError.chunkDownloadFailed("Cannot write a game file (errno \(errno)).") }
                written += n
            }
        }
    }

    private nonisolated static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SteamError.chunkDownloadFailed("Invalid content URL.") }
        try Task.checkCancellation()
        let (data, response) = try await http.data(from: url)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw SteamError.chunkDownloadFailed("Content server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    // MARK: - Manifest

    private func fetchManifest(depotID: UInt32, appID: UInt32, manifestGID: UInt64,
                               key: Data, hosts: [String]) async throws -> DepotManifest {
        let requestCode = try await manifestRequestCode(depotID: depotID, appID: appID, manifestGID: manifestGID)
        var lastError: Error = SteamError.manifestFetchFailed("No content server returned the manifest.")
        for host in hosts.prefix(6) {
            try Task.checkCancellation()
            let auth = await cdnAuthFragment(depotID: depotID, appID: appID, host: host)
            let code = requestCode == 0 ? "" : "/\(requestCode)"
            do {
                let raw = try await Self.download("\(host)/depot/\(depotID)/manifest/\(manifestGID)/5\(code)\(auth)")
                let parsing = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try Self.parseManifest(raw, depotID: depotID, manifestGID: manifestGID, key: key)
                }
                let manifest = try await withTaskCancellationHandler {
                    try await parsing.value
                } onCancel: {
                    parsing.cancel()
                }
                try Task.checkCancellation()
                return manifest
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                SteamLog.trace("manifest from a content server failed: \(Self.failureReason(error))")
            }
        }
        throw lastError
    }

    private nonisolated static func parseManifest(_ raw: Data, depotID: UInt32, manifestGID: UInt64, key: Data) throws -> DepotManifest {
        try parseManifestKeepingPayload(raw, depotID: depotID, manifestGID: manifestGID, key: key).0
    }

    /// The manifest and the binary manifest bytes it was parsed from (unzipped, decrypted).
    private nonisolated static func parseManifestKeepingPayload(_ raw: Data, depotID: UInt32, manifestGID: UInt64,
                                                                key: Data) throws -> (DepotManifest, Data) {
        // Content servers deliver the manifest as a single-entry ZIP.
        try Task.checkCancellation()
        guard raw.count <= ContentDecryptor.maximumChunkBytes * 4 else {
            throw SteamError.manifestFetchFailed("Manifest exceeds the supported size")
        }
        let payload = raw.starts(with: [0x50, 0x4B]) ? try unzipSingleFile(raw) : raw
        if let plain = try? DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: payload, depotKey: key),
           !plain.files.isEmpty {
            return (plain, payload)
        }
        // Older depots encrypt the whole manifest with the depot key.
        try Task.checkCancellation()
        let decrypted = try ContentDecryptor.decryptChunk(encryptedData: payload, depotKey: key)
        let inflated = (try? ContentDecryptor.decompressChunk(compressedData: decrypted, expectedSize: 0)) ?? decrypted
        return (try DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: inflated, depotKey: key), inflated)
    }

    /// Extract the single deflated entry from a manifest ZIP. No zip lib needed —
    /// parse the local file header and inflate the raw deflate stream.
    nonisolated static func unzipSingleFile(_ data: Data) throws -> Data {
        let data = Data(data)  // zero-based indices
        guard data.count > 30,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw SteamError.manifestFetchFailed("Not a zip")
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24 }
        let method = u16(8)
        let compSize = u32(18)
        let uncompSize = u32(22)
        let nameLen = u16(26), extraLen = u16(28)
        let start = 30 + nameLen + extraLen
        guard start + compSize <= data.count, method == 0 || method == 8,
              uncompSize <= ContentDecryptor.maximumChunkBytes * 4 else {
            throw SteamError.manifestFetchFailed("Bad zip entry (method \(method))")
        }
        let entry = data.subdata(in: start..<(start + compSize))
        if method == 0 {
            guard entry.count == uncompSize, zipCRC(entry) == UInt32(u32(14)) else {
                throw SteamError.checksumMismatch
            }
            return entry
        }

        // Zip stores raw deflate — inflate with zlib, negative windowBits
        var strm = z_stream()
        let cap = max(uncompSize, 1024)
        var out = Data(count: cap)
        var n = -1
        entry.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                strm.avail_in = UInt32(entry.count)
                strm.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                strm.avail_out = UInt32(cap)
                guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                let r = inflate(&strm, Z_FINISH)
                inflateEnd(&strm)
                if r == Z_STREAM_END { n = Int(strm.total_out) }
            }
        }
        guard n == uncompSize else { throw SteamError.decompressionFailed }
        out.count = n
        guard zipCRC(out) == UInt32(u32(14)) else { throw SteamError.checksumMismatch }
        return out
    }

    private nonisolated static func zipCRC(_ data: Data) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(truncatingIfNeeded: zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count)))
        }
    }

    // MARK: - Depot Key

    private func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        if let cached = depotKeys[depotID] { return cached }
        try await session.ensureConnected()

        var request = CMsgClientGetDepotDecryptionKey()
        request.depotID = depotID
        request.appID = appID

        let response = try await session.sendAndWait(
            eMsg: .clientGetDepotDecryptionKey,
            body: request.serialize(),
            responseEMsg: .clientGetDepotDecryptionKeyResponse,
            timeout: 15
        )

        let keyResponse = try CMsgClientGetDepotDecryptionKeyResponse.deserialize(from: response.body)
        // Steam only issues keys for depots this account owns.
        guard EResult(rawValue: UInt32(keyResponse.eresult))?.isSuccess == true,
              keyResponse.depotEncryptionKey.count == 32 else {
            SteamLog.event("[steam-depot] depot-key refused app=\(appID) depot=\(depotID) eresult=\(keyResponse.eresult)")
            throw SteamError.depotKeyNotFound(depotID)
        }

        depotKeys[depotID] = keyResponse.depotEncryptionKey
        return keyResponse.depotEncryptionKey
    }

    // MARK: - Manifest Request Code

    private func manifestRequestCode(depotID: UInt32, appID: UInt32, manifestGID: UInt64) async throws -> UInt64 {
        try await session.ensureConnected()
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: appID)
        encoder.writeUInt32(fieldNumber: 2, value: depotID)
        encoder.writeUInt64(fieldNumber: 3, value: manifestGID)

        let responseData = try await session.callServiceMethod(
            method: .getManifestRequestCode,
            body: encoder.data,
            timeout: 15
        )

        var decoder = ProtobufDecoder(responseData)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1 {
                // manifest_request_code is fixed64 on the wire
                return tag.wireType == .fixed64 ? try decoder.readFixed64() : try decoder.readVarint()
            }
            try decoder.skip(wireType: tag.wireType)
        }

        return 0 // No request code needed (older depots)
    }

    // MARK: - CDN Discovery + Auth

    /// Content server discovery via the public Web API
    /// (IContentServerDirectoryService/GetServersForSteamPipe). No account
    /// token is attached; the directory does not require one.
    enum ServerEligibility: Equatable { case usable, noHTTPS, other }

    /// Directory fields as served by GetServersForSteamPipe: https_support
    /// ("mandatory", "optional", "unavailable"), use_as_proxy, and an optional
    /// allowed_app_ids restriction.
    nonisolated static func serverEligibility(_ server: [String: Any], appID: UInt32) -> ServerEligibility {
        if let https = (server["https_support"] as? String)?.lowercased(), https != "mandatory", https != "optional" {
            return .noHTTPS
        }
        if (server["use_as_proxy"] as? Bool) == true || (server["use_as_proxy"] as? NSNumber)?.boolValue == true {
            return .other
        }
        if let allowed = server["allowed_app_ids"] as? [Any], !allowed.isEmpty,
           !allowed.contains(where: { ($0 as? NSNumber)?.uint32Value == appID || ($0 as? String) == String(appID) }) {
            return .other
        }
        return .usable
    }

    private func contentServers(appID: UInt32) async throws -> [String] {
        var hosts: [String] = []
        do {
            guard let url = URL(string: "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=\(session.cellID)&max_servers=20") else {
                throw SteamError.chunkDownloadFailed("Bad content directory URL")
            }
            let (data, response) = try await Self.http.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SteamError.chunkDownloadFailed("Content directory HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = json["response"] as? [String: Any],
                  let servers = resp["servers"] as? [[String: Any]] else {
                throw SteamError.chunkDownloadFailed("Content directory returned unexpected data")
            }
            // In the directory's order. The directory marks some CDN servers
            // https_support "unavailable"; requesting them over HTTPS fails the
            // TLS handshake (NSURLError -1200). Such servers, proxy-only entries
            // and servers restricted to other apps are skipped.
            var skippedHTTP = 0, skippedOther = 0
            for server in servers {
                let host = (server["vhost"] as? String) ?? (server["host"] as? String) ?? ""
                guard Self.usableContentHost(host) else { skippedOther += 1; continue }
                switch Self.serverEligibility(server, appID: appID) {
                case .usable: break
                case .noHTTPS: skippedHTTP += 1; continue
                case .other: skippedOther += 1; continue
                }
                let entry = "https://\(host)"
                if !hosts.contains(entry) { hosts.append(entry) }
            }
            SteamLog.event("[steam-cdn] offered=\(servers.count) usable=\(hosts.count) skipped-no-https=\(skippedHTTP) skipped-other=\(skippedOther)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SteamLog.trace("content directory failed: \(Self.failureReason(error))")
        }
        let fallback = "https://steampipe.akamaized.net"
        if !hosts.contains(fallback) { hosts.append(fallback) }
        return hosts
    }

    nonisolated static func usableContentHost(_ host: String) -> Bool {
        guard host.contains("."), !host.contains(" "), !host.contains("/"), !host.contains("*"),
              !host.contains("lancache"), !host.contains(":") else { return false }
        return host.hasSuffix(".steamcontent.com") || host.hasSuffix(".akamaized.net") ||
            host.hasSuffix(".steampipe.steamcontent.com") || host.hasSuffix(".steamstatic.com")
    }

    /// Unified-service GetCDNAuthToken → "?auth=…" query fragment for this
    /// depot on this host. An empty token is normal outside regional edge
    /// networks. Cached per depot and host.
    private func cdnAuthFragment(depotID: UInt32, appID: UInt32, host: String) async -> String {
        let cacheKey = "\(depotID)|\(host)"
        if let cached = cdnAuthTokens[cacheKey] { return cached }

        // host_name must be the bare hostname, not the https:// URL
        let bareHost = URL(string: host)?.host ?? host

        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)  // depot_id = 1
        encoder.writeString(fieldNumber: 2, value: bareHost) // host_name = 2
        encoder.writeUInt32(fieldNumber: 3, value: appID)    // app_id = 3

        do {
            try await session.ensureConnected()
            let responseData = try await session.callServiceMethod(
                method: .getCDNAuthToken,
                body: encoder.data,
                timeout: 10
            )
            var decoder = ProtobufDecoder(responseData)
            var token = ""
            while let tag = try decoder.readTag() {
                if tag.fieldNumber == 1 { token = try decoder.readString() } else { try decoder.skip(wireType: tag.wireType) }
            }
            let fragment = token.isEmpty ? "" : (token.hasPrefix("?") || token.hasPrefix("&") ? token : "?auth=\(token)")
            cdnAuthTokens[cacheKey] = fragment
            return fragment
        } catch {
            SteamLog.trace("content authorization request failed; continuing without a token")
            cdnAuthTokens[cacheKey] = ""
            return ""
        }
    }
}

/// Per-install content-server health. Chunks start on different servers
/// (spreading load) and servers that keep failing move to the back of every
/// chunk's rotation, instead of each chunk rediscovering a bad server.
/// Manifest path checks, from iDeck's SteamInstall.swift (Copyright 2026 125hz).
enum SteamInstallFiles {
    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String],
                                             isDirectory: Bool = false) -> String? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 && !isDirectory { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }
}

final class ContentHostHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var reported = 0

    func order(_ hosts: [String], seed: Int) -> [String] {
        guard !hosts.isEmpty else { return hosts }
        let rotated = (0..<hosts.count).map { hosts[($0 + seed) % hosts.count] }
        lock.lock(); let counts = failures; lock.unlock()
        return rotated.enumerated()
            .sorted { ((counts[$0.element] ?? 0), $0.offset) < ((counts[$1.element] ?? 0), $1.offset) }
            .map(\.element)
    }

    func recordFailure(_ host: String, reason: String) {
        lock.lock()
        failures[host, default: 0] += 1
        let report = failures[host] == 3 && reported < 8
        if report { reported += 1 }
        lock.unlock()
        if report {
            let server = host.replacingOccurrences(of: "https://", with: "")
            DispatchQueue.main.async { SteamLog.event("[steam-cdn] host demoted host=\(server) reason=\(reason)") }
        }
    }

    func recordSuccess(_ host: String) {
        lock.lock()
        if let count = failures[host], count > 0 { failures[host] = count - 1 }
        lock.unlock()
    }
}

/// Append-only record of completed chunks for one depot manifest. Lines are
/// hexadecimal work-item keys. A lost tail only causes those chunks to be
/// fetched again.
final class JournalWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0
    private var closed = false

    init(url: URL) throws {
        let root = try SteamContentFileRoot(url: url.deletingLastPathComponent())
        let fd = try root.openFile(url.lastPathComponent, writing: true, create: true)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { buffer = "\n" }
            _ = try handle.seekToEnd()
        }
    }

    func append(_ key: UInt64) throws {
        buffer += String(key, radix: 16) + "\n"
        pending += 1
        if pending >= 64 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""; pending = 0
    }

    func close() throws {
        guard !closed else { return }
        try flush()
        try handle.close()
        closed = true
    }

    static func load(_ url: URL) -> Set<UInt64> {
        guard let root = try? SteamContentFileRoot(url: url.deletingLastPathComponent()),
              let fd = try? root.openFile(url.lastPathComponent, writing: false, create: false) else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        // The journal is an optimization. Bound it and discard malformed tails;
        // all claimed complete chunks are SHA1-checked against actual bytes.
        guard let bytes = try? handle.read(upToCount: 16 * 1024 * 1024),
              let text = String(data: bytes, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { UInt64($0, radix: 16) })
    }
}

/// One immutable directory descriptor shared by structured chunk workers.
/// The C helpers duplicate it and walk children without following links; the
/// descriptor stays alive until every worker and detached preparation drains.
final class SteamContentFileRoot: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        guard url.isFileURL else { throw SteamFileError.invalid("A local game folder is required.") }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        descriptor = path.withCString { bo1_steam_open_root($0) }
        guard descriptor >= 0 else {
            throw SteamFileError.invalid("The game folder must be an accessible real directory (errno \(errno)).")
        }
    }

    deinit { close(descriptor) }

    func openFile(_ relative: String, writing: Bool, create: Bool) throws -> Int32 {
        let fd = relative.withCString { bo1_steam_open_file(descriptor, $0, writing ? 1 : 0, create ? 1 : 0) }
        guard fd >= 0 else {
            throw SteamError.chunkDownloadFailed("Cannot safely open a game file (errno \(errno)).")
        }
        return fd
    }

    func makeDirectory(_ relative: String) throws {
        guard relative.withCString({ bo1_steam_make_directory(descriptor, $0) }) == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot safely create a game directory (errno \(errno)).")
        }
    }
}
