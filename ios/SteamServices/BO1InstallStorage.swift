// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO1 iOS contributors
import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct BO1PublishFile: Sendable {
    let relativePath: String
    let source: URL
}

struct BO1InstallReceipt: Codable, Sendable {
    var selection: BO1PackageSelection
    var planFingerprint: String
    var files: [String]
    var installedAt: Date
}

/// Serial, joined filesystem transaction. All operations below the opened app
/// roots use no-follow descriptor-relative C helpers, including metadata and
/// digest reads. A renamed/symlinked path cannot redirect a later file write.
final class BO1InstallStorage: @unchecked Sendable {
    static let markerName = ".bo1-install-in-progress.json"
    let gameDirectory: URL
    let workDirectory: URL
    private var gameRoot: Root?
    private var workRoot: Root?
    private var game: Root { gameRoot! }
    private var work: Root { workRoot! }
    private let journalPath = "publish/journal.json"
    private let receiptPath = "installed.json"

    private struct Entry: Codable {
        var relativePath: String
        var targetPath: String
        var sourcePath: String
        var backupName: String
        var hadOriginal: Bool
        var digest: String
    }
    private struct Journal: Codable {
        var version = 1
        var phase = "applying"
        var completed = 0
        var entries: [Entry]
        var receipt: BO1InstallReceipt
    }

    init(gameDirectory: URL, workDirectory: URL) {
        self.gameDirectory = Self.systemCanonicalURL(gameDirectory)
        self.workDirectory = Self.systemCanonicalURL(workDirectory)
    }

    func prepare() throws { try openRoots(); try recover() }

    func loadReceipt() -> BO1InstallReceipt? {
        guard (try? openRoots()) != nil,
              let data = try? work.read(receiptPath, limit: 32 * 1024 * 1024) else { return nil }
        return try? JSONDecoder().decode(BO1InstallReceipt.self, from: data)
    }

    func publish(files: [BO1PublishFile], receipt: BO1InstallReceipt,
                 check: @Sendable () throws -> Void = { try Task.checkCancellation() },
                 afterStep: ((Int) throws -> Void)? = nil) throws {
        try prepare()
        try check()
        guard !(try work.exists(journalPath)) else {
            throw BO1DownloadError.invalid("The previous install's private recovery files could not be cleaned up. Retry after resolving the storage error.")
        }
        guard !files.isEmpty, files.count <= 500_000 else {
            throw BO1DownloadError.invalid("The completed download has no publishable files or exceeds the supported file count.")
        }
        var entries: [Entry] = []
        var folded: [String: String] = [:]
        for file in files {
            try check()
            let relative = try Self.relative(file.relativePath)
            guard relative.caseInsensitiveCompare(Self.markerName) != .orderedSame else {
                throw BO1DownloadError.invalid("A selected depot conflicts with installer metadata.")
            }
            let source = Self.systemCanonicalURL(file.source)
            guard Self.contains(workDirectory, source), source != workDirectory else {
                throw BO1DownloadError.invalid("A staged file is outside the private download folder.")
            }
            let sourcePath = try Self.relative(String(source.path.dropFirst(workDirectory.path.count + 1)))
            guard !sourcePath.hasPrefix("publish/"), sourcePath != receiptPath else {
                throw BO1DownloadError.invalid("A staged file conflicts with private installer metadata.")
            }
            let digest = try work.digest(sourcePath, check: check)
            let key = relative.lowercased()
            if let previous = folded[key] {
                guard previous == digest else {
                    throw BO1DownloadError.invalid("Selected packages contain conflicting versions of \(relative). Choose fewer optional packages and retry.")
                }
                continue
            }
            folded[key] = digest
            let target = try targetPath(relative)
            entries.append(Entry(relativePath: relative, targetPath: target, sourcePath: sourcePath,
                backupName: "\(entries.count)", hadOriginal: try game.exists(target), digest: digest))
        }
        try work.makeDirectory("publish")
        var record = Journal(entries: entries, receipt: receipt)
        record.receipt.files = entries.map(\.relativePath).sorted()
        try save(record)
        do {
            try check()
            try game.writeAtomic(Data("BO1 install publication in progress\n".utf8), at: Self.markerName, replacing: false)
            for index in record.entries.indices {
                try check()
                let entry = record.entries[index]
                guard try work.digest(entry.sourcePath, check: check) == entry.digest else {
                    throw BO1DownloadError.invalid("A staged file changed before it could be installed. Run Continue / repair again.")
                }
                let exists = try game.exists(entry.targetPath)
                guard exists == entry.hadOriginal else {
                    throw BO1DownloadError.invalid("The game folder changed while preparing the install. No further files were published.")
                }
                if exists { try game.move(entry.targetPath, to: work, path: "publish/" + entry.backupName) }
                try check()
                try work.move(entry.sourcePath, to: game, path: entry.targetPath)
                record.completed = index + 1
                try save(record)
                try afterStep?(record.completed)
            }
            try check()
            record.phase = "committed"
            try save(record)
            try finishCommitted(record)
        } catch {
            // Recovery ignores cancellation and drains before dismissal. If
            // recovery fails, retain the marker and never claim a paused install
            // is ready to use. Journal recovery covers process interruption;
            // it is not a promise of full power-loss filesystem durability.
            do { try recover() }
            catch { throw BO1DownloadError.recoveryRequired }
            throw error
        }
    }

    func recover() throws {
        try openRoots()
        guard try work.exists(journalPath) else {
            guard try work.listIfPresent("publish").isEmpty else {
                throw BO1DownloadError.invalid("Private recovery files exist without their journal. They were preserved; a new install cannot reuse that recovery folder.")
            }
            // exists also rejects dangling links and nonregular marker entries.
            if try game.exists(Self.markerName) {
                throw BO1DownloadError.invalid("The game folder has an unfinished-install marker but no recovery journal. Preserve the files and restore the missing journal or a known-good backup.")
            }
            return
        }
        let record = try JSONDecoder().decode(Journal.self, from: work.read(journalPath, limit: 64 * 1024 * 1024))
        guard record.version == 1, record.entries.count <= 500_000,
              record.phase == "applying" || record.phase == "committed" else {
            throw BO1DownloadError.invalid("The install recovery journal is not recognized.")
        }
        for entry in record.entries {
            _ = try Self.relative(entry.relativePath)
            _ = try Self.relative(entry.targetPath)
            _ = try Self.relative(entry.sourcePath)
            guard !entry.backupName.isEmpty, entry.backupName.allSatisfy({ $0.isASCII && $0.isNumber }),
                  entry.digest.count == 64, !entry.sourcePath.hasPrefix("publish/"), entry.sourcePath != receiptPath,
                  entry.targetPath.caseInsensitiveCompare(Self.markerName) != .orderedSame else {
                throw BO1DownloadError.invalid("The install recovery journal is invalid.")
            }
        }
        if record.phase == "committed" { try finishCommitted(record); return }
        for entry in record.entries.reversed() {
            let backup = "publish/" + entry.backupName
            let hasSource = try work.exists(entry.sourcePath)
            let hasTarget = try game.exists(entry.targetPath)
            let hasBackup = try work.exists(backup)
            if hasBackup || (!entry.hadOriginal && !hasSource && hasTarget) {
                if hasTarget {
                    guard !hasSource, try game.digest(entry.targetPath) == entry.digest else {
                        throw BO1DownloadError.invalid("A file changed outside the installer during recovery. It was preserved; automatic rollback was stopped.")
                    }
                    try game.move(entry.targetPath, to: work, path: entry.sourcePath)
                }
                if hasBackup { try work.move(backup, to: game, path: entry.targetPath) }
            } else if entry.hadOriginal && !hasSource && !hasBackup {
                throw BO1DownloadError.invalid("A recovery backup is missing. The installer will not guess which game file to remove.")
            }
        }
        try game.remove(Self.markerName)
        try? work.removeTree("publish")
    }

    /// Remove only this completed plan's private cache after publication. Never
    /// called on cancelled work, so verified chunks remain resumable.
    func discardCompletedStaging(key: String) {
        guard key.count == 64, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return }
        try? workRoot?.removeTree("staging/" + key)
        try? workRoot?.removeTree("journals/" + key)
    }

    private func finishCommitted(_ record: Journal) throws {
        try work.writeAtomic(JSONEncoder().encode(record.receipt), at: receiptPath)
        try game.remove(Self.markerName)
        try? work.removeTree("publish")
    }
    private func save(_ record: Journal) throws { try work.writeAtomic(JSONEncoder().encode(record), at: journalPath) }

    private func openRoots() throws {
        if gameRoot != nil && workRoot != nil { return }
        guard gameDirectory.isFileURL, workDirectory.isFileURL,
              !Self.contains(gameDirectory, workDirectory), !Self.contains(workDirectory, gameDirectory) else {
            throw BO1DownloadError.invalid("The game and private download folders must be separate local folders.")
        }
        let first = gameDirectory.pathComponents, second = workDirectory.pathComponents
        var shared: [String] = []
        for pair in zip(first, second) { if pair.0 != pair.1 { break }; shared.append(pair.0) }
        guard shared.count > 1 else { throw BO1DownloadError.invalid("Install folders must share a trusted app-container parent.") }
        let base = URL(fileURLWithPath: NSString.path(withComponents: shared), isDirectory: true)
        // Only the trusted common app-container ancestor is opened by absolute
        // path. Game/work descendants are created/opened through its retained fd.
        try Self.prepareTrustedBase(base)
        let descriptor = base.path.withCString { bo1_steam_open_root($0) }
        guard descriptor >= 0 else { throw Self.fileError("open the app's download container") }
        let container = Root(descriptor: descriptor)
        let gamePath = String(gameDirectory.path.dropFirst(base.path.count + 1))
        let workPath = String(workDirectory.path.dropFirst(base.path.count + 1))
        try container.makeDirectory(gamePath)
        try container.makeDirectory(workPath)
        gameRoot = try container.directory(gamePath)
        workRoot = try container.directory(workPath)
    }

    private static func prepareTrustedBase(_ base: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in base.pathComponents where component != "/" {
            current.appendPathComponent(component, isDirectory: true)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw BO1DownloadError.invalid("The app-container parent is not a real directory.")
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private func targetPath(_ relative: String) throws -> String {
        var components: [String] = []
        for component in relative.split(separator: "/").map(String.init) {
            let prefix = components.joined(separator: "/")
            let matches = try game.listIfPresent(prefix).filter { $0.caseInsensitiveCompare(component) == .orderedSame }
            guard matches.count <= 1 else { throw BO1DownloadError.invalid("The game folder contains ambiguous case variants. Preserve one spelling before repairing.") }
            components.append(matches.first ?? component)
        }
        return components.joined(separator: "/")
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/") || candidate.path == root.path
    }
    private static func systemCanonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        for prefix in ["/var", "/tmp"] where standardized.path == prefix || standardized.path.hasPrefix(prefix + "/") {
            let resolved = URL(fileURLWithPath: prefix, isDirectory: true).resolvingSymlinksInPath().path
            return URL(fileURLWithPath: resolved + String(standardized.path.dropFirst(prefix.count)))
        }
        return standardized
    }
    private static func relative(_ name: String) throws -> String {
        let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), name.utf8.count < 1024,
              pieces.count <= 64, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") &&
                  !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }) else {
            throw BO1DownloadError.invalid("An install path is not a contained relative file path.")
        }
        return name
    }
    private static func fileError(_ action: String) -> BO1DownloadError {
        .invalid("The installer could not \(action) safely (filesystem error \(errno)). Files were preserved.")
    }

    private final class Root {
        let descriptor: Int32
        init(descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
        func exists(_ path: String) throws -> Bool {
            let result = path.withCString { bo1_steam_file_exists(descriptor, $0) }
            guard result >= 0 else { throw BO1InstallStorage.fileError("inspect a contained file") }
            return result == 1
        }
        func directory(_ path: String) throws -> Root {
            let fd = path.withCString { bo1_steam_open_directory(descriptor, $0) }
            guard fd >= 0 else { throw BO1InstallStorage.fileError("open a contained directory") }
            return Root(descriptor: fd)
        }
        func makeDirectory(_ path: String) throws {
            guard path.withCString({ bo1_steam_make_directory(descriptor, $0) }) == 0 else {
                throw BO1InstallStorage.fileError("create a contained directory")
            }
        }
        func open(_ path: String, writing: Bool = false, create: Bool = false) throws -> FileHandle {
            let fd = path.withCString { bo1_steam_open_file(descriptor, $0, writing ? 1 : 0, create ? 1 : 0) }
            guard fd >= 0 else { throw BO1InstallStorage.fileError("open a contained regular file") }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        func read(_ path: String, limit: Int) throws -> Data {
            let handle = try open(path)
            defer { try? handle.close() }
            var result = Data()
            while let part = try handle.read(upToCount: min(1024 * 1024, limit + 1 - result.count)), !part.isEmpty {
                result.append(part)
                guard result.count <= limit else { throw BO1DownloadError.invalid("The install metadata exceeds its size limit.") }
            }
            return result
        }
        func digest(_ path: String, check: @Sendable () throws -> Void = {}) throws -> String {
            let handle = try open(path)
            defer { try? handle.close() }
            var hash = SHA256()
            while true {
                try check()
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func move(_ source: String, to root: Root, path: String, replacing: Bool = false) throws {
            let result = source.withCString { from in path.withCString { to in
                replacing ? bo1_steam_replace_file(descriptor, from, root.descriptor, to) :
                    bo1_steam_move_file(descriptor, from, root.descriptor, to)
            }}
            guard result == 0 else { throw BO1InstallStorage.fileError("move a contained file") }
        }
        func remove(_ path: String) throws {
            guard path.withCString({ bo1_steam_remove_file(descriptor, $0) }) == 0 else {
                throw BO1InstallStorage.fileError("remove installer metadata")
            }
        }
        func writeAtomic(_ data: Data, at path: String, replacing: Bool = true) throws {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            let temporary = (parent.isEmpty ? "" : parent + "/") + ".bo1-write-" + UUID().uuidString
            do {
                let handle = try open(temporary, writing: true, create: true)
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    try handle.close()
                } catch { try? handle.close(); throw error }
                try move(temporary, to: self, path: path, replacing: replacing)
            } catch { try? remove(temporary); throw error }
        }
        func listIfPresent(_ path: String) throws -> [String] {
            let fd = path.withCString { bo1_steam_open_directory(descriptor, $0) }
            if fd < 0 && errno == ENOENT { return [] }
            guard fd >= 0 else { throw BO1InstallStorage.fileError("inspect a contained directory") }
            guard let stream = fdopendir(fd) else { close(fd); throw BO1InstallStorage.fileError("read a contained directory") }
            defer { closedir(stream) }
            // An empty relative path duplicates the retained root descriptor;
            // dup shares its directory offset, so every listing starts over.
            rewinddir(stream)
            var result: [String] = []
            errno = 0
            while let pointer = readdir(stream) {
                var entry = pointer.pointee
                let name = withUnsafePointer(to: &entry.d_name) { buffer in
                    String(validatingUTF8: UnsafeRawPointer(buffer).assumingMemoryBound(to: CChar.self))
                }
                guard let name else { throw BO1DownloadError.invalid("A game filename is not valid UTF-8.") }
                if name != "." && name != ".." { result.append(name) }
                errno = 0
            }
            guard errno == 0 else { throw BO1InstallStorage.fileError("finish reading a contained directory") }
            return result
        }
        func removeTree(_ path: String) throws {
            let fd = path.withCString { bo1_steam_open_directory(descriptor, $0) }
            if fd < 0 && errno == ENOENT { return }
            guard fd >= 0 else { throw BO1InstallStorage.fileError("open private cleanup directory") }
            close(fd)
            // A crash during transaction cleanup must leave the journal as
            // evidence until every backup and temporary entry is gone. An
            // empty directory without a journal is safe to reuse; orphaned
            // backup files without a journal are rejected by recover().
            let names = try listIfPresent(path).sorted { left, right in
                if left == "journal.json" { return false }
                if right == "journal.json" { return true }
                return left < right
            }
            for name in names {
                let child = path + "/" + name
                let regular = child.withCString { bo1_steam_file_exists(descriptor, $0) }
                if regular == 1 { try remove(child) }
                else if regular == 0 { continue }
                else { try removeTree(child) }
            }
            guard path.withCString({ bo1_steam_remove_directory(descriptor, $0) }) == 0 else {
                throw BO1InstallStorage.fileError("remove an empty private directory")
            }
        }
    }
}
