// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic metadata and temporary files only: no Steam login or game assets.
import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

private final class Checks {
    private(set) var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String,
               line: UInt = #line) throws {
        count += 1
        let passed = try condition()
        if !passed { throw CheckFailure(description: "line \(line): \(message)") }
    }
    func rejects(_ message: String, _ operation: () throws -> Void,
                 line: UInt = #line) throws {
        count += 1
        do { try operation() } catch { return }
        throw CheckFailure(description: "line \(line): accepted \(message)")
    }
}

private func depot(_ id: UInt32, _ manifest: UInt64? = 1,
                   language: String = "", os: String = "windows", arch: String = "",
                   dlc: UInt32? = nil, from: UInt32? = nil,
                   shared: Bool = false, lowViolence: Bool = false,
                   bytes: UInt64 = 10) -> BO1DepotMetadata {
    var result = BO1DepotMetadata(id: id, manifest: manifest)
    result.language = language; result.oslist = os; result.arch = arch
    result.dlcAppID = dlc; result.fromApp = from
    result.sharedInstall = shared; result.lowViolence = lowViolence
    result.downloadBytes = bytes; result.diskBytes = bytes
    return result
}

private func app(_ id: UInt32, _ depots: [BO1DepotMetadata]) -> BO1AppMetadata {
    BO1AppMetadata(id: id, name: "Synthetic app \(id)", depots: depots)
}

private func selectionTests(_ checks: Checks) throws {
    try checks.check(BO1DLC.firstStrike.id == 42716, "First Strike ownership AppID")
    try checks.check(BO1DLC.escalation.id == 42718, "Escalation ownership AppID")
    try checks.check(BO1DLC.annihilation.id == 42722, "Annihilation ownership AppID")
    try checks.check(BO1DLC.rezurrection.id == 42719, "Rezurrection ownership AppID")

    var metadata: [UInt32: BO1AppMetadata] = [
        42700: app(42700, [depot(101), depot(102, language: "english"),
            depot(103, language: "german"), depot(104, os: "linux"),
            depot(105, arch: "32"), depot(106, arch: "64"),
            depot(107, dlc: 42716), depot(108, from: 42718),
            depot(109, shared: true), depot(110, lowViolence: true)]),
        42710: app(42710, [depot(201), depot(202, language: "english")])
    ]
    var selection = BO1PackageSelection()
    let plan = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    try checks.check(plan.steps.count == 1 && plan.steps[0].appID == 42700, "base only")
    try checks.check(Set(plan.steps.flatMap(\.depotIDs)) == [101, 102, 105],
                     "only Windows common/English x86 base depots")
    try checks.check(plan.estimatedDownloadBytes == 30 && plan.estimatedDiskBytes == 30,
                     "only selected data contributes to estimates")
    try checks.check(BO1InstallSelection.languages(in: metadata, multiplayer: false) == ["english", "german"],
                     "base language choices")
    try checks.check(BO1InstallSelection.languages(in: metadata, multiplayer: true) == ["english"],
                     "MP language intersection")
    try checks.rejects("unowned base app") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42710])
    }
    selection.multiplayer = true
    try checks.rejects("unowned multiplayer app") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    }
    let both = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42710])
    try checks.check(Set(both.steps.map(\.appID)) == [42700, 42710], "explicit owned MP included")
    selection.language = "german"
    try checks.rejects("language missing from MP") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42710])
    }
    selection.multiplayer = false
    let german = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    try checks.check(Set(german.steps.flatMap(\.depotIDs)) == [101, 103, 105], "German replaces English localization")
    selection.language = "../english"
    try checks.rejects("invalid language syntax") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    }
    selection = BO1PackageSelection()
    selection.dlcAppIDs = [42716]
    try checks.rejects("selected unowned DLC") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    }
    selection.dlcAppIDs = [999999]
    try checks.rejects("unrecognized DLC despite a license") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 999999])
    }
    selection.dlcAppIDs = [42719]
    try checks.rejects("owned DLC without an explicit depot relationship") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42719])
    }
    selection.dlcAppIDs = [42716]
    metadata[42700] = app(42700, [depot(101), depot(301, dlc: 42716)])
    metadata[42710] = app(42710, [depot(201), depot(302, dlc: 42716)])
    let dlcSP = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42716])
    try checks.check(Set(dlcSP.steps.flatMap(\.depotIDs)) == [101, 301],
                     "MP-off does not pull DLC from unselected/unowned MP parent")
    let ownedButOff = try BO1InstallSelection.makePlan(selection: selection, apps: metadata,
                                                     ownedApps: [42700, 42710, 42716])
    try checks.check(Set(ownedButOff.steps.flatMap(\.depotIDs)) == [101, 301],
                     "owning MP does not override its off toggle")
    selection.multiplayer = true
    let dlcBoth = try BO1InstallSelection.makePlan(selection: selection, apps: metadata,
                                                ownedApps: [42700, 42710, 42716])
    try checks.check(Set(dlcBoth.steps.flatMap(\.depotIDs)) == [101, 201, 301, 302],
                     "selected MP includes its explicit DLC depots")
    selection.multiplayer = false
    metadata[42716] = app(42716, [depot(303)])
    let directAndParent = try BO1InstallSelection.makePlan(selection: selection, apps: metadata,
                                                        ownedApps: [42700, 42716])
    try checks.check(Set(directAndParent.steps.flatMap(\.depotIDs)) == [101, 301, 303],
                     "direct DLC and parent-attached content are both retained")

    selection = BO1PackageSelection()
    metadata = [42700: app(42700, [depot(401, nil)])]
    try checks.rejects("missing public manifest") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    }
    metadata = [42700: app(42700, [depot(401, 0)])]
    try checks.rejects("zero public manifest") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    }
    metadata = [42700: app(42700, [depot(401, 11)]), 42710: app(42710, [depot(401, 11), depot(402, 12)])]
    selection.multiplayer = true
    let shared = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42710])
    try checks.check(shared.steps.flatMap(\.depotIDs).filter { $0 == 401 }.count == 1,
                     "same depot+manifest is downloaded once across apps")
    metadata[42710] = app(42710, [depot(401, 13)])
    try checks.rejects("conflicting manifests for the same selected depot") {
        _ = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700, 42710])
    }
    selection.multiplayer = false
    metadata = [42700: app(42700, [depot(401, 11, bytes: .max), depot(402, 12, bytes: 1)])]
    let oversized = try BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: [42700])
    try checks.check(oversized.estimatedDownloadBytes == .max && oversized.estimatedDiskBytes == .max,
                     "metadata byte estimates saturate instead of trapping")
    try checks.check(plan.fingerprint != german.fingerprint, "resume identity changes with selected localization")
}

private func kvString(_ name: String, _ value: String) -> Data {
    var data = Data([1])
    data.append(contentsOf: name.utf8); data.append(0)
    data.append(contentsOf: value.utf8); data.append(0)
    return data
}
private func kvInteger(_ name: String, _ value: UInt32) -> Data {
    var data = Data([2])
    data.append(contentsOf: name.utf8); data.append(0)
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    return data
}
private func kvObject(_ name: String, _ children: Data) -> Data {
    var data = Data([0])
    data.append(contentsOf: name.utf8); data.append(0)
    data.append(children); data.append(8)
    return data
}
private func package(_ children: Data) -> Data {
    var data = Data([1, 0, 0, 0])
    data.append(kvObject("123", children)); data.append(8)
    return data
}

private func parserTests(_ checks: Checks) throws {
    let apps = kvObject("appids", kvInteger("0", 42700) + kvString("1", "42716"))
    let depots = kvObject("depotids", kvInteger("0", 9001)) // synthetic, not a BO1 depot table
    let valid = package(apps + depots)
    try checks.check(try VDFParser.parsePackageAppIDs(from: valid) == [42700, 42716], "binary PICS retains owned DLC apps")
    try checks.check(try VDFParser.parsePackageIDs(key: "depotids", from: valid) == [9001], "app and depot entitlements remain separate")
    let falseText = package(kvString("description", "appids") + kvInteger("0", 999999) + apps)
    try checks.check(try VDFParser.parsePackageAppIDs(from: falseText) == [42700, 42716],
                     "an appids string value cannot confer ownership")
    let nested = package(kvObject("metadata", kvObject("appids", kvInteger("0", 999999))) + apps)
    try checks.check(try VDFParser.parsePackageAppIDs(from: nested) == [42700, 42716],
                     "nested unrelated appids section cannot confer ownership")
    try checks.check(try VDFParser.parsePackageAppIDs(from: package(depots)).isEmpty, "depot-only package does not invent app ownership")
    try checks.rejects("duplicate entitlement sections") {
        _ = try VDFParser.parsePackageAppIDs(from: package(apps + apps))
    }
    try checks.rejects("zero entitlement ID") {
        _ = try VDFParser.parsePackageAppIDs(from: package(kvObject("appids", kvInteger("0", 0))))
    }
    try checks.rejects("nonnumeric entitlement index") {
        _ = try VDFParser.parsePackageAppIDs(from: package(kvObject("appids", kvInteger("other", 42700))))
    }
    try checks.rejects("truncated package terminator") {
        _ = try VDFParser.parsePackageAppIDs(from: Data(valid.dropLast()))
    }
    var unknown = Data([255]); unknown.append(contentsOf: "unknown".utf8); unknown.append(0)
    try checks.rejects("unknown binary KeyValues type") { _ = try VDFParser.parsePackageAppIDs(from: package(unknown)) }
    var deep = kvInteger("0", 1)
    for index in 0..<33 { deep = kvObject("level\(index)", deep) }
    try checks.rejects("excessively nested package metadata") { _ = try VDFParser.parsePackageAppIDs(from: package(deep)) }
    try checks.rejects("unsupported package format") {
        var bytes = valid; bytes[0] = 2
        _ = try VDFParser.parsePackageAppIDs(from: bytes)
    }
    try checks.rejects("trailing package bytes") { _ = try VDFParser.parsePackageAppIDs(from: valid + Data([0])) }

    var encoded = ProtobufEncoder(); encoded.writeVarint(UInt64.max)
    var maxDecoder = ProtobufDecoder(encoded.data)
    try checks.check(try maxDecoder.readVarint() == .max, "UInt64 maximum varint decodes")
    try checks.rejects("overflowing tenth varint byte") {
        var decoder = ProtobufDecoder(Data(repeating: 255, count: 9) + Data([2]))
        _ = try decoder.readVarint()
    }
    try checks.rejects("oversized protobuf byte length") {
        var decoder = ProtobufDecoder(encoded.data)
        _ = try decoder.readBytes()
    }
    var skip = ProtobufDecoder(Data([0x0a, 3, 0xaa, 0xbb, 0xcc, 0x10, 1]))
    let first = try skip.readTag()
    try checks.check(first?.fieldNumber == 1, "unknown length-delimited test field")
    try skip.skip(wireType: .lengthDelimited)
    let second = try skip.readTag()
    let secondValue = try skip.readVarint()
    try checks.check(second?.fieldNumber == 2 && secondValue == 1,
                     "skipping length-delimited data lands on next field")

    var owner = SteamAppInfo(appID: 42716)
    var original = SteamAppInfo.DepotInfo(depotID: 501)
    original.dlcAppID = 42716; original.isSharedInstall = true
    original.language = "english"; original.oslist = "windows"; original.osarch = "32"
    original.manifests = ["public": 42]
    owner.depots = [original]
    var consumer = SteamAppInfo(appID: 42700)
    var shared = SteamAppInfo.DepotInfo(depotID: 501)
    shared.fromApp = 42716; shared.manifests = ["public": 77]
    consumer.depots = [shared]
    _ = consumer.inheritDepots(from: [42716: owner])
    try checks.check(consumer.depots[0].dlcAppID == 42716 && consumer.depots[0].isSharedInstall,
                     "shared ownership restrictions inherit even when consumer already has a manifest")
    try checks.check(consumer.depots[0].language == "english" && consumer.depots[0].osarch == "32",
                     "missing shared language/architecture fields inherit")
    try checks.check(consumer.installDepots().isEmpty, "restricted shared content is excluded from automatic base selection")
}

private final class InstallFixture: @unchecked Sendable {
    let root: URL
    let game: URL
    let work: URL
    let storage: BO1InstallStorage
    init() throws {
        // Intentionally retain the system spelling (/var/folders on macOS).
        // Normal sandbox ancestors must not be mistaken for user symlinks.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bo1-install-test-" + UUID().uuidString)
        game = root.appendingPathComponent("game")
        work = root.appendingPathComponent("private-work")
        storage = BO1InstallStorage(gameDirectory: game, workDirectory: work)
        try storage.prepare()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func stage(_ path: String, _ text: String) throws -> BO1PublishFile {
        let source = work.appendingPathComponent("stage").appendingPathComponent(path)
        try write(source, text)
        return BO1PublishFile(relativePath: path, source: source)
    }
    func text(_ path: String) throws -> String {
        try String(contentsOf: game.appendingPathComponent(path), encoding: .utf8)
    }
    var marker: URL { game.appendingPathComponent(BO1InstallStorage.markerName) }
}

private func receipt(_ label: String, files: [BO1PublishFile]) -> BO1InstallReceipt {
    BO1InstallReceipt(selection: BO1PackageSelection(), planFingerprint: label,
                      files: files.map(\.relativePath), installedAt: Date(timeIntervalSince1970: 1))
}

private final class AccountCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 1
    func switchAccount() { lock.lock(); current = 2; lock.unlock() }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        if current != 1 { throw BO1DownloadError.accountChanged }
    }
}

private func runCrashChild(_ root: URL) throws -> Never {
    let game = root.appendingPathComponent("game")
    let work = root.appendingPathComponent("private-work")
    let files = ["zone/Common/common.ff", "main/new.iwd"].map {
        BO1PublishFile(relativePath: $0, source: work.appendingPathComponent("stage").appendingPathComponent($0))
    }
    let storage = BO1InstallStorage(gameDirectory: game, workDirectory: work)
    try storage.publish(files: files, receipt: receipt("interrupted", files: files), afterStep: { completed in
        if completed == 1 { _exit(73) }
    })
    throw CheckFailure(description: "crash failpoint was not reached")
}

private func crashAfterFirstFile(_ fixture: InstallFixture, checks: Checks) throws {
    try fixture.write(fixture.game.appendingPathComponent("zone/Common/common.ff"), "old-common")
    _ = try fixture.stage("zone/Common/common.ff", "new-common")
    _ = try fixture.stage("main/new.iwd", "new-archive")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--crash-mid-install", fixture.root.path]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    try checks.check(process.terminationStatus == 73, "child reached real publication failpoint: \(detail)")
    try checks.check(FileManager.default.fileExists(atPath: fixture.marker.path), "interruption retains startup marker")
    try checks.check(try fixture.text("zone/Common/common.ff") == "new-common", "first file was exposed before interruption")
}

private func storageTests(_ checks: Checks) async throws {
    let fm = FileManager.default
    do {
        let f = try InstallFixture()
        try f.write(f.game.appendingPathComponent("zone/Common/common.ff"), "original")
        try f.write(f.game.appendingPathComponent("MAIN/SECOND.IWD"), "old-second")
        try f.write(f.game.appendingPathComponent("players/profile.cfg"), "user-settings")
        let files = [try f.stage("ZONE/common/COMMON.FF", "installed"),
                     try f.stage("main/second.iwd", "second-installed"), try f.stage("main/new.iwd", "archive")]
        try f.storage.publish(files: files, receipt: receipt("complete", files: files))
        try checks.check(try f.text("zone/Common/common.ff") == "installed", "replaces selected bytes using existing case spelling")
        try checks.check(try f.text("MAIN/SECOND.IWD") == "second-installed", "successive root scans preserve a second differently-cased existing path")
        let names = try fm.contentsOfDirectory(atPath: f.game.path)
        try checks.check(names.filter { $0.caseInsensitiveCompare("main") == .orderedSame } == ["MAIN"],
                         "multiple published files do not create a duplicate top-level case variant")
        try checks.check(try f.text("players/profile.cfg") == "user-settings", "unselected user files survive publication")
        try checks.check(try f.text("main/new.iwd") == "archive", "new manifest file installed")
        try checks.check(!fm.fileExists(atPath: f.marker.path), "successful publication clears startup marker")
        try checks.check(f.storage.loadReceipt()?.planFingerprint == "complete", "receipt appears only after complete publication")
        try f.storage.recover()
        try checks.check(try f.text("zone/Common/common.ff") == "installed", "recovery after success does not undo committed data")
    }
    do {
        let f = try InstallFixture()
        let baseline = [try f.stage("zone/Common/common.ff", "old-common")]
        try f.storage.publish(files: baseline, receipt: receipt("old-receipt", files: baseline))
        let files = [try f.stage("zone/Common/common.ff", "new-common"), try f.stage("main/new.iwd", "new-archive")]
        try checks.rejects("injected error after first published file") {
            try f.storage.publish(files: files, receipt: receipt("failed", files: files), afterStep: { completed in
                if completed == 1 { throw CheckFailure(description: "injected write boundary failure") }
            })
        }
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "failure restores the overwritten original")
        try checks.check(!fm.fileExists(atPath: f.game.appendingPathComponent("main/new.iwd").path), "failure does not expose later files")
        try checks.check(f.storage.loadReceipt()?.planFingerprint == "old-receipt", "failure preserves previous completed receipt")
        try checks.check(!fm.fileExists(atPath: f.marker.path), "completed rollback clears startup block")
        try checks.check(fm.fileExists(atPath: files[0].source.path), "rolled-back staged bytes remain resumable")
    }
    do {
        let f = try InstallFixture()
        try f.write(f.game.appendingPathComponent("zone/Common/common.ff"), "old-common")
        let files = [try f.stage("zone/Common/common.ff", "new-common"), try f.stage("main/new.iwd", "new-archive")]
        let task = Task.detached {
            try f.storage.publish(files: files, receipt: receipt("cancelled", files: files), afterStep: { completed in
                if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        var cancelled = false
        do { try await task.value } catch is CancellationError { cancelled = true }
        try checks.check(cancelled, "actual cancelled Swift task fails publication")
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "cancellation joins rollback before returning")
        try checks.check(!fm.fileExists(atPath: f.marker.path) && f.storage.loadReceipt() == nil,
                         "cancelled transaction is not a completed install")
    }
    do {
        let f = try InstallFixture()
        try f.write(f.game.appendingPathComponent("zone/Common/common.ff"), "old-common")
        let files = [try f.stage("zone/Common/common.ff", "new-common"), try f.stage("main/new.iwd", "new-archive")]
        let account = AccountCheck()
        var stopped = false
        do {
            try f.storage.publish(files: files, receipt: receipt("switched-account", files: files),
                                  check: { try account.validate() }, afterStep: { completed in
                if completed == 1 { account.switchAccount() }
            })
        } catch BO1DownloadError.accountChanged { stopped = true }
        try checks.check(stopped, "changed-account validation is honored during publication")
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "account change rolls back already-published bytes")
        try checks.check(!fm.fileExists(atPath: f.marker.path), "account-change rollback completes before dismissal")
    }
    do {
        let f = try InstallFixture()
        try crashAfterFirstFile(f, checks: checks)
        try f.storage.recover()
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "fresh-process recovery restores backup")
        try checks.check(!fm.fileExists(atPath: f.game.appendingPathComponent("main/new.iwd").path), "recovery leaves unpublished file absent")
        try checks.check(!fm.fileExists(atPath: f.marker.path) && f.storage.loadReceipt() == nil,
                         "recovered interrupted install is not marked successful")
        try f.storage.recover()
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "rollback recovery is repeatable")
    }
    do {
        let f = try InstallFixture()
        try crashAfterFirstFile(f, checks: checks)
        try f.write(f.game.appendingPathComponent("zone/Common/common.ff"), "external-edit")
        try checks.rejects("external file change during crash recovery") { try f.storage.recover() }
        try checks.check(try f.text("zone/Common/common.ff") == "external-edit", "recovery preserves externally changed content")
        try checks.check(fm.fileExists(atPath: f.marker.path), "unresolved recovery keeps startup blocked")
        try f.write(f.game.appendingPathComponent("zone/Common/common.ff"), "new-common")
        try f.storage.recover()
        try checks.check(try f.text("zone/Common/common.ff") == "old-common", "restored expected transaction state can recover")
    }
    do {
        let f = try InstallFixture()
        let first = try f.stage("one.bin", "one")
        let second = try f.stage("two.bin", "two")
        let collision = [BO1PublishFile(relativePath: "same.ff", source: first.source),
                         BO1PublishFile(relativePath: "SAME.FF", source: second.source)]
        try checks.rejects("case-insensitive conflicting package files") {
            try f.storage.publish(files: collision, receipt: receipt("collision", files: collision))
        }
        try checks.check(!fm.fileExists(atPath: f.marker.path), "conflicting inputs fail before startup is blocked")
        let escaping = [BO1PublishFile(relativePath: "../escape", source: first.source)]
        try checks.rejects("publication path traversal") {
            try f.storage.publish(files: escaping, receipt: receipt("escape", files: escaping))
        }
        let reserved = [BO1PublishFile(relativePath: BO1InstallStorage.markerName.uppercased(), source: first.source)]
        try checks.rejects("case-folded reserved install marker") {
            try f.storage.publish(files: reserved, receipt: receipt("reserved", files: reserved))
        }
        let external = f.root.appendingPathComponent("external.bin")
        try f.write(external, "outside-private-stage")
        let outside = [BO1PublishFile(relativePath: "selected.bin", source: external)]
        try checks.rejects("staged source outside private workspace") {
            try f.storage.publish(files: outside, receipt: receipt("outside", files: outside))
        }
        let linked = f.work.appendingPathComponent("linked.bin")
        try fm.createSymbolicLink(at: linked, withDestinationURL: external)
        let symlink = [BO1PublishFile(relativePath: "selected.bin", source: linked)]
        try checks.rejects("staged source symlink") {
            try f.storage.publish(files: symlink, receipt: receipt("symlink", files: symlink))
        }
        let hardlink = f.work.appendingPathComponent("hardlink.bin")
        try fm.linkItem(at: first.source, to: hardlink)
        try checks.rejects("staged source with external hardlink") {
            try f.storage.publish(files: [first], receipt: receipt("hardlink", files: [first]))
        }
        try checks.check(try String(contentsOf: external, encoding: .utf8) == "outside-private-stage", "rejected sources stay unchanged")
    }
    do {
        let f = try InstallFixture()
        try fm.createSymbolicLink(at: f.marker, withDestinationURL: f.work.appendingPathComponent("missing"))
        try checks.rejects("dangling unfinished-install marker without journal") { try f.storage.recover() }
        try checks.check((try? fm.destinationOfSymbolicLink(atPath: f.marker.path)) != nil,
                         "unknown dangling marker is preserved for explicit recovery")
        let nested = BO1InstallStorage(gameDirectory: f.game, workDirectory: f.game.appendingPathComponent("private"))
        try checks.rejects("private staging nested inside game folder") { try nested.prepare() }
    }
    do {
        let f = try InstallFixture()
        // Represents interruption after an older cleanup lost its journal but
        // before it removed a backup. This must never seed a new transaction.
        let orphan = f.work.appendingPathComponent("publish/0")
        try f.write(orphan, "unexplained-old-backup")
        let files = [try f.stage("new-selected.bin", "new-selected-content")]
        try checks.rejects("unexplained publication backups without a journal") {
            try f.storage.publish(files: files, receipt: receipt("must-not-start", files: files))
        }
        try checks.check(!fm.fileExists(atPath: f.game.appendingPathComponent("new-selected.bin").path),
                         "orphan backup prevents the next publication before target mutation")
        try checks.check(try String(contentsOf: orphan, encoding: .utf8) == "unexplained-old-backup",
                         "orphan backup is preserved rather than attached to a new plan")
    }
}

@MainActor private func contentTests(_ checks: Checks) async throws {
    let fm = FileManager.default
    let fixture = try InstallFixture()
    let staging = fixture.work.appendingPathComponent("download")
    let journals = fixture.work.appendingPathComponent("journals")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    try fm.createDirectory(at: journals, withIntermediateDirectories: true)
    // SHA1("abc"), a public deterministic test vector, not downloaded content.
    let sha = Data([0xa9,0x99,0x3e,0x36,0x47,0x06,0x81,0x6a,0xba,0x3e,
                    0x25,0x71,0x78,0x50,0xc2,0x6c,0x9c,0xd0,0xd8,0x9d])
    let chunk = DepotManifest.ChunkEntry(sha: sha, crc: 0, offset: 0, compressedSize: 3, uncompressedSize: 3)
    let entry = DepotManifest.FileEntry(filename: "data.bin", size: 3, flags: 0, chunks: [chunk])
    let manifest = DepotManifest(depotID: 1, manifestGID: 7, creationTime: 0,
                                 totalUncompressedSize: 3, totalCompressedSize: 3, files: [entry])
    let plan = DepotDownloader.DepotPlan(depotID: 1, manifestGID: 7, key: Data(repeating: 0, count: 32),
                                        manifest: manifest, hosts: [], auth: [:], declaredSize: 3,
                                        health: ContentHostHealth())
    let dataFile = staging.appendingPathComponent("data.bin")
    let journal = journals.appendingPathComponent("depot_1_7.journal")
    try Data("0\n".utf8).write(to: journal)
    try Data("abc".utf8).write(to: dataFile)
    try checks.check(DepotDownloader.matchesSHA(Data("abc".utf8), expected: sha), "download hash matches known SHA1")
    try checks.check(!DepotDownloader.matchesSHA(Data("xyz".utf8), expected: sha), "wrong bytes cannot satisfy chunk hash")
    let verified = try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    try checks.check(verified.doneBytes == 3 && verified.pending[0].isEmpty, "journal credit requires existing matching chunk")
    try Data("xyz".utf8).write(to: dataFile)
    let corrupt = try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    try checks.check(corrupt.doneBytes == 0 && corrupt.pending[0].count == 1, "stale journal does not trust corrupted bytes")
    try fm.removeItem(at: dataFile)
    let deleted = try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    try checks.check(deleted.doneBytes == 0 && deleted.pending[0].count == 1, "stale journal does not trust recreated sparse file")
    try Data("a".utf8).write(to: dataFile)
    let truncated = try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    try checks.check(truncated.doneBytes == 0 && truncated.pending[0].count == 1, "stale journal does not trust extended truncated file")
    try Data("abc".utf8).write(to: dataFile)
    let root = try SteamContentFileRoot(url: staging)
    try checks.check(DepotDownloader.verifiedChunk(chunk, root: root, path: "data.bin") == Data("abc".utf8),
                     "chunk reuse reads and verifies through contained root")
    try fm.removeItem(at: dataFile)
    let outside = fixture.root.appendingPathComponent("outside.bin")
    try Data("abc".utf8).write(to: outside)
    try fm.createSymbolicLink(at: dataFile, withDestinationURL: outside)
    try checks.check(DepotDownloader.verifiedChunk(chunk, root: root, path: "data.bin") == nil,
                     "chunk reuse never follows a symlink")
    try checks.rejects("staged symlink on resumed preparation") {
        _ = try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    }
    try checks.check(try Data(contentsOf: outside) == Data("abc".utf8), "rejected resume leaves outside bytes intact")
    try fm.removeItem(at: dataFile)

    try DepotDownloader.validateFile(entry)
    try checks.rejects("chunk beyond file bounds") {
        let bad = DepotManifest.ChunkEntry(sha: sha, crc: 0, offset: 3, compressedSize: 3, uncompressedSize: 3)
        try DepotDownloader.validateFile(DepotManifest.FileEntry(filename: "x", size: 3, flags: 0, chunks: [bad]))
    }
    try checks.rejects("chunk gap") {
        try DepotDownloader.validateFile(DepotManifest.FileEntry(filename: "x", size: 4, flags: 0, chunks: [chunk]))
    }
    try checks.rejects("overlapping chunk ranges") {
        try DepotDownloader.validateFile(DepotManifest.FileEntry(filename: "x", size: 6, flags: 0, chunks: [chunk, chunk]))
    }
    try checks.rejects("invalid SHA1 size") {
        let bad = DepotManifest.ChunkEntry(sha: Data(repeating: 0, count: 19), crc: 0, offset: 0, compressedSize: 3, uncompressedSize: 3)
        try DepotDownloader.validateFile(DepotManifest.FileEntry(filename: "x", size: 3, flags: 0, chunks: [bad]))
    }
    try checks.rejects("truncated binary manifest header") {
        _ = try DepotManifest.parse(depotID: 1, manifestGID: 7, data: Data(repeating: 0, count: 6))
    }
    let cancelled = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try DepotDownloader.prepare(plans: [plan], installURL: staging, journalDir: journals, existingURL: nil)
    }
    var stopped = false
    do { _ = try await cancelled.value } catch is CancellationError { stopped = true }
    try checks.check(stopped && !fm.fileExists(atPath: dataFile.path), "cancelled preparation cannot recreate a staged file")
}

@main
private enum BO1SteamSelectionStorageTests {
    static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash-mid-install" {
            try runCrashChild(URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        let checks = Checks()
        var phase = "selection"
        do {
            try selectionTests(checks)
            phase = "parser"
            try parserTests(checks)
            phase = "storage"
            try await storageTests(checks)
            phase = "content"
            try await contentTests(checks)
        } catch {
            let message = "Steam host test failed in \(phase) phase after \(checks.count) checks: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            throw error
        }
        print("Steam selection/storage: \(checks.count) checks passed")
    }
}
