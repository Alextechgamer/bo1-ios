// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO1 iOS contributors
// Uses the pinned BO2/Madeira Steam services; see SteamAuth notices.
import Combine
import CryptoKit
import Foundation
import UIKit

extension BO1AppMetadata {
    init(_ app: SteamAppInfo) {
        id = app.appID
        name = app.name
        depots = app.depots.map {
            BO1DepotMetadata(id: $0.depotID, manifest: $0.publicManifestID, language: $0.language,
                oslist: $0.oslist, arch: $0.osarch, dlcAppID: $0.dlcAppID, fromApp: $0.fromApp,
                sharedInstall: $0.isSharedInstall, lowViolence: $0.lowViolence,
                downloadBytes: $0.publicDownloadBytes > 0 ? $0.publicDownloadBytes : $0.maxSize,
                diskBytes: $0.publicSizeBytes > 0 ? $0.publicSizeBytes : $0.maxSize)
        }
    }
}

@MainActor
final class BO1GameFilesCoordinator: ObservableObject {
    enum Activity: Equatable { case idle, recovering, loading, downloading, publishing, stopping }
    @Published var selection = BO1PackageSelection()
    @Published private(set) var activity: Activity = .recovering
    @Published private(set) var status = "Checking the game folder…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var accountName: String?
    @Published private(set) var ownedAppIDs = Set<UInt32>()
    @Published private(set) var metadata: [UInt32: BO1AppMetadata] = [:]
    @Published private(set) var progress: SteamDownloadProgress?
    @Published private(set) var currentPackage = ""
    @Published private(set) var receipt: BO1InstallReceipt?
    @Published private(set) var folderReady = false
    @Published private(set) var accountTransition = false
    private(set) var completionError: NSError?
    var closeRequested: ((Bool) -> Void)?

    let gameDirectory: URL
    private let storage: BO1InstallStorage
    private let session: any SteamCMSession
    private var operation: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var operationID: UUID?
    private var revision: UInt64
    private var catalogSteamID: UInt64 = 0
    private var catalogRevision: UInt64?
    private var observers: [NSObjectProtocol] = []
    private var backgrounded = false
    private var closing = false
    private var stopMessage = "Download paused. Completed chunks are retained; Continue / repair resumes verification."
    private var savedIdleTimer: Bool?

    var busy: Bool { activity != .idle || accountTransition }
    var writing: Bool { activity == .recovering || activity == .downloading || activity == .publishing || activity == .stopping }
    var signedIn: Bool { SteamSignIn.isSignedIn }
    var availableLanguages: [String] { BO1InstallSelection.languages(in: metadata, multiplayer: selection.multiplayer) }
    var canDownload: Bool {
        folderReady && !busy && !backgrounded && signedIn && catalogRevision == SteamSignIn.revision &&
            ownedAppIDs.contains(BO1InstallSelection.baseApp)
    }
    var approximateBytes: UInt64? {
        (try? BO1InstallSelection.makePlan(selection: selection, apps: metadata, ownedApps: ownedAppIDs))?.estimatedDownloadBytes
    }

    convenience init(directory: URL) { self.init(directory: directory, session: SteamSession()) }

    init(directory: URL, session: any SteamCMSession) {
        gameDirectory = directory.standardizedFileURL
        self.session = session
        revision = SteamSignIn.revision
        accountName = SteamSignIn.accountName
        backgrounded = UIApplication.shared.applicationState == .background
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Separate roots keep staging out of Files and out of the playable tree.
        let pathKey = Self.hash(directory.standardizedFileURL.path)
        storage = BO1InstallStorage(gameDirectory: directory,
            workDirectory: support.appendingPathComponent("BO1SteamDownloads/\(pathKey)", isDirectory: true))
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: SteamSignIn.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.credentialsChanged() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.backgrounded = false
                self.accountName = SteamSignIn.accountName
                if self.revision != SteamSignIn.revision { self.credentialsChanged() }
                else if self.metadata.isEmpty && !self.busy && self.folderReady { self.refresh() }
            }
        })
        session.identityDidChange = { [weak self] id in
            guard let self, self.catalogSteamID != 0, id != self.catalogSteamID else { return }
            self.operation?.cancel()
        }
        recoverFolder()
    }

    deinit {
        operation?.cancel()
        transition?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func recoverFolder() {
        begin(.recovering) { [self] in
            let worker = Task.detached(priority: .userInitiated) { [storage] in try storage.prepare() }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            folderReady = true
            receipt = storage.loadReceipt()
            if let receipt { selection = receipt.selection }
            status = receipt == nil ? "Choose your Steam packages or copy files into the game folder." : "A completed install is present. Continue / repair verifies the selected files."
        } after: { [weak self] in
            guard let self, self.folderReady, self.signedIn, !self.backgrounded, !self.closing else { return }
            self.refresh()
        }
    }

    func retryRecovery() { guard !busy else { return }; recoverFolder() }

    func refresh() {
        guard !busy, !closing, !backgrounded else { return }
        accountName = SteamSignIn.accountName
        guard signedIn else { status = "Sign in to Steam to check your Black Ops packages."; return }
        begin(.loading) { [self] in
            let accountRevision = SteamSignIn.revision
            status = "Reading this account's Black Ops licenses from Steam…"
            let loaded = try await loadCatalog(language: selection.language, expectedRevision: accountRevision)
            try checkAccount(accountRevision, steamID: loaded.steamID)
            ownedAppIDs = loaded.owned
            metadata = loaded.apps.mapValues(BO1AppMetadata.init)
            catalogSteamID = loaded.steamID
            catalogRevision = accountRevision
            selection.dlcAppIDs.formIntersection(ownedAppIDs)
            if !ownedAppIDs.contains(BO1InstallSelection.multiplayerApp) { selection.multiplayer = false }
            let languages = availableLanguages
            if !languages.contains(selection.language), let first = languages.first { selection.language = first }
            status = ownedAppIDs.contains(BO1InstallSelection.baseApp)
                ? "Choose the files to install. Downloads start only when you tap Continue / repair."
                : "This account's Steam licenses do not include Call of Duty: Black Ops (42700)."
        }
    }

    private struct Catalog {
        var steamID: UInt64
        var owned: Set<UInt32>
        var apps: [UInt32: SteamAppInfo]
        var fetcher: SteamLibraryFetcher
    }

    private func loadCatalog(language: String, expectedRevision: UInt64) async throws -> Catalog {
        try checkAccount(expectedRevision)
        try await session.ensureConnected()
        try checkAccount(expectedRevision)
        let id = session.steamID
        guard id != 0 else { throw SteamError.invalidCredentials }
        let fetcher = SteamLibraryFetcher(session: session)
        let owned = try await fetcher.ownedAppIDs()
        try checkAccount(expectedRevision, steamID: id)
        var apps: [UInt32: SteamAppInfo] = [:]
        let requested = [BO1InstallSelection.baseApp, BO1InstallSelection.multiplayerApp] +
            BO1DLC.allCases.filter { owned.contains($0.id) }.map(\.id)
        for appID in requested {
            try checkAccount(expectedRevision, steamID: id)
            if let info = try await fetcher.fetchInstallInfo(appID: appID, language: language, includeDLC: true) {
                apps[appID] = info
            }
        }
        try checkAccount(expectedRevision, steamID: id)
        return Catalog(steamID: id, owned: owned, apps: apps, fetcher: fetcher)
    }

    func startDownload() {
        guard canDownload else { return }
        let requested = selection
        begin(.downloading) { [self] in
            // CDN traffic does not reset the CM session's idle timer. Keep the
            // authenticated connection leased until all publication work drains.
            let connectionLease = try session.acquireRuntimeLease()
            defer { session.releaseRuntimeLease(connectionLease) }
            savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { restoreIdleTimer() }
            let accountRevision = SteamSignIn.revision
            status = "Checking the selected packages with Steam…"
            // Fresh metadata, licenses and downloader keys per attempt/account.
            let loaded = try await loadCatalog(language: requested.language, expectedRevision: accountRevision)
            let projected = loaded.apps.mapValues(BO1AppMetadata.init)
            let plan = try BO1InstallSelection.makePlan(selection: requested, apps: projected, ownedApps: loaded.owned)
            try checkAccount(accountRevision, steamID: loaded.steamID)
            let key = Self.hash(plan.fingerprint)
            let staging = storage.workDirectory.appendingPathComponent("staging/\(key)", isDirectory: true)
            let journals = storage.workDirectory.appendingPathComponent("journals/\(key)", isDirectory: true)
            let downloader = DepotDownloader(session: session)
            var publishFiles: [BO1PublishFile] = []
            for (index, step) in plan.steps.enumerated() {
                try checkAccount(accountRevision, steamID: loaded.steamID)
                guard let info = loaded.apps[step.appID] else { throw BO1DownloadError.invalid("A selected package's metadata is missing.") }
                let target = staging.appendingPathComponent(String(step.appID), isDirectory: true)
                currentPackage = "\(step.title) · \(index + 1) of \(plan.steps.count)"
                status = "Downloading and verifying \(step.title)…"
                let result = try await downloader.install(info, into: target, journals: journals,
                    selectedDepotIDs: Set(step.depotIDs), reusing: storage.gameDirectory,
                    ownedDepots: { try? await loaded.fetcher.ownedDepotIDs() },
                    progress: { [weak self] value in
                        guard let self, SteamSignIn.revision == accountRevision else { return }
                        self.progress = value
                    })
                try checkAccount(accountRevision, steamID: loaded.steamID)
                publishFiles += result.relativeFiles.map { BO1PublishFile(relativePath: $0, source: target.appendingPathComponent($0)) }
            }
            try checkAccount(accountRevision, steamID: loaded.steamID)
            activity = .publishing
            progress = nil
            status = "Safely publishing the verified files. Keep the app open…"
            let completed = BO1InstallReceipt(selection: requested, planFingerprint: plan.fingerprint,
                files: publishFiles.map(\.relativePath), installedAt: Date())
            let worker = Task.detached(priority: .userInitiated) { [storage, publishFiles] in
                try storage.publish(files: publishFiles, receipt: completed, check: {
                    try Task.checkCancellation()
                    guard SteamSignIn.revision == accountRevision else { throw BO1DownloadError.accountChanged }
                })
                storage.discardCompletedStaging(key: key)
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            receipt = storage.loadReceipt()
            progress = nil
            currentPackage = ""
            status = "The selected game files are installed. This app still has no available game engine."
        }
    }

    func pause() {
        guard operation != nil else { return }
        stopMessage = "Paused. Completed chunks are retained; Continue / repair verifies and resumes them."
        activity = .stopping
        operation?.cancel()
    }

    func cancelAndWait(closing: Bool = false) async {
        if closing { self.closing = true }
        if let task = operation {
            activity = .stopping
            task.cancel()
            await task.value
        }
        if let task = transition { await task.value }
        if closing { await session.disconnectGracefully() }
        restoreIdleTimer()
    }

    func pauseForBackground() async {
        backgrounded = true
        accountTransition = true
        stopMessage = "Paused because the app entered the background. Return here and tap Continue / repair to resume."
        await cancelAndWait()
        await session.disconnectGracefully()
        accountTransition = transition != nil
    }

    func requestClose(cancelled: Bool) {
        guard !closing else { return }
        closing = true
        closeRequested?(cancelled)
    }

    private func credentialsChanged() {
        guard revision != SteamSignIn.revision else { return }
        revision = SteamSignIn.revision
        let changedRevision = revision
        accountName = SteamSignIn.accountName
        catalogSteamID = 0; catalogRevision = nil
        ownedAppIDs = []; metadata = [:]
        selection.dlcAppIDs = []; selection.multiplayer = false
        stopMessage = BO1DownloadError.accountChanged.localizedDescription
        operation?.cancel()
        accountTransition = true
        let previous = transition
        let pending = operation
        transition = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            if let pending { await pending.value }
            guard let self else { return }
            await self.session.disconnectGracefully()
            guard self.revision == changedRevision else { return }
            self.transition = nil
            self.accountTransition = false
            self.status = self.stopMessage
            if !self.closing && !self.backgrounded && self.signedIn && self.folderReady { self.refresh() }
        }
    }

    private func checkAccount(_ expected: UInt64, steamID: UInt64? = nil) throws {
        try Task.checkCancellation()
        guard SteamSignIn.revision == expected, SteamSignIn.isSignedIn,
              steamID == nil || session.steamID == steamID else { throw BO1DownloadError.accountChanged }
    }

    private func begin(_ kind: Activity, work: @escaping @MainActor () async throws -> Void,
                       after: (@MainActor () -> Void)? = nil) {
        guard operation == nil, !accountTransition, !closing else { return }
        let id = UUID()
        operationID = id
        activity = kind
        errorMessage = nil
        completionError = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await work() }
            catch {
                if case BO1DownloadError.recoveryRequired = error {
                    self.folderReady = false
                    self.errorMessage = error.localizedDescription
                    self.completionError = error as NSError
                    self.status = "Recovery is required before game files can be used."
                } else if error is CancellationError || Task.isCancelled && !(error is BO1DownloadError) {
                    self.status = self.stopMessage
                    self.completionError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                } else {
                    self.errorMessage = SteamSignIn.message(error)
                    self.completionError = error as NSError
                    self.status = "The operation stopped. Existing files and resumable downloads were preserved."
                }
            }
            guard self.operationID == id else { return }
            self.restoreIdleTimer()
            self.operation = nil
            self.operationID = nil
            self.activity = .idle
            if !self.closing && !self.accountTransition { after?() }
        }
    }

    private func restoreIdleTimer() {
        if let savedIdleTimer { UIApplication.shared.isIdleTimerDisabled = savedIdleTimer; self.savedIdleTimer = nil }
    }
    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
