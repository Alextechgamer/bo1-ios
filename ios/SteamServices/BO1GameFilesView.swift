// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO1 iOS contributors
import SwiftUI

struct BO1GameFilesView: View {
    @ObservedObject var model: BO1GameFilesCoordinator
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Black Ops game files").font(.title2.bold())
                        Text("Sign in to Steam and download the copy you own. Campaign and Zombies are required; other packages are optional.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                Section("Steam account") {
                    if let account = model.accountName {
                        LabeledContent("Signed in", value: account)
                        Button("Manage Steam sign-in") { showSignIn = true }.disabled(model.busy)
                    } else {
                        Button("Sign in to Steam") { showSignIn = true }.disabled(model.busy)
                    }
                    Button("Refresh packages") { model.refresh() }
                        .disabled(model.busy || !model.signedIn || !model.folderReady)
                }
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("Campaign and Zombies")
                            Text(baseSubtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Required").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $model.selection.multiplayer) {
                        VStack(alignment: .leading) {
                            Text("Multiplayer / Combat Training")
                            if !model.ownedAppIDs.contains(BO1InstallSelection.multiplayerApp) {
                                Text(model.metadata.isEmpty ? "Check your Steam packages first" : "Not listed in this account's licenses")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(model.busy || !model.ownedAppIDs.contains(BO1InstallSelection.multiplayerApp))
                    if !model.availableLanguages.isEmpty {
                        Picker("Language", selection: $model.selection.language) {
                            ForEach(model.availableLanguages, id: \.self) { language in
                                Text(languageLabel(language)).tag(language)
                            }
                        }.disabled(model.busy || model.metadata.isEmpty)
                    }
                } header: { Text("Packages") }
                footer: { Text("Package and language choices come from Steam's current product information. Unselecting a package does not remove previously installed files.") }

                Section("Owned DLC · optional") {
                    ForEach(BO1DLC.allCases) { dlc in
                        Toggle(isOn: Binding(
                            get: { model.selection.dlcAppIDs.contains(dlc.id) },
                            set: { enabled in
                                if enabled { model.selection.dlcAppIDs.insert(dlc.id) }
                                else { model.selection.dlcAppIDs.remove(dlc.id) }
                            })) {
                            VStack(alignment: .leading) {
                                Text(dlc.name)
                                Text(model.ownedAppIDs.contains(dlc.id) ? "Owned" : (model.metadata.isEmpty ? "Not checked" : "Not owned"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(model.busy || !model.ownedAppIDs.contains(dlc.id))
                    }
                }

                Section {
                    Text(model.status)
                    if !model.currentPackage.isEmpty { Text(model.currentPackage).font(.subheadline).foregroundStyle(.secondary) }
                    if let progress = model.progress {
                        if progress.phase == .downloading && progress.totalBytes > 0 {
                            ProgressView(value: progress.fraction)
                            Text("\(bytes(progress.doneBytes)) of \(bytes(progress.totalBytes)) · \(speed(progress.bytesPerSecond))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            ProgressView(progress.phase == .finishing ? "Finishing verification…" : "Preparing and checking existing chunks…")
                        }
                    } else if model.busy { ProgressView() }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if !model.folderReady {
                        Button("Retry folder recovery") { model.retryRecovery() }.disabled(model.busy)
                    } else if model.activity == .downloading || model.activity == .publishing || model.activity == .stopping {
                        Button(model.activity == .stopping ? "Stopping safely…" : "Pause download", role: .cancel) { model.pause() }
                            .disabled(model.activity == .stopping)
                    } else {
                        Button("Continue / repair") { model.startDownload() }
                            .fontWeight(.semibold).disabled(!model.canDownload)
                    }
                    if let estimate = model.approximateBytes, estimate > 0, !model.busy {
                        Text("About \(bytes(estimate)) of compressed content selected. Existing matching chunks are reused. Temporary space is needed to preserve the current install during repair.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Download and verify") }
                footer: { Text("Keep the app open while downloading. Backgrounding pauses the operation; completed chunks remain available to resume.") }

                Section("Files app") {
                    Text("You can also copy your game files into Files → On My iPhone → \(appName) → game.")
                    Text("Downloads are staged privately, then published into this same game folder. Unrelated files and saves are preserved.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let receipt = model.receipt {
                        LabeledContent("Last completed selection", value: receipt.installedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Text("Game files can be installed here, but the native game engine is not yet available in this app. Completing a download does not start a game.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Game Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.requestClose(cancelled: true) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.requestClose(cancelled: false) }.disabled(model.busy)
                }
            }
            .sheet(isPresented: $showSignIn, onDismiss: {
                if !model.busy && model.signedIn { model.refresh() }
            }) { SteamSignInView() }
        }
    }

    private var baseSubtitle: String {
        if model.metadata.isEmpty { return "Check your Steam packages first" }
        return model.ownedAppIDs.contains(BO1InstallSelection.baseApp) ? "Owned · App 42700" : "Not listed in this account's licenses"
    }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Black Ops 1"
    }
    private func languageLabel(_ language: String) -> String {
        let names = ["english": "English", "french": "French", "german": "German", "italian": "Italian",
            "spanish": "Spanish", "russian": "Russian", "polish": "Polish", "japanese": "Japanese",
            "koreana": "Korean", "schinese": "Simplified Chinese", "tchinese": "Traditional Chinese"]
        return names[language] ?? language.capitalized
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    private func speed(_ value: Double) -> String {
        String(format: "%.1f MB/s", max(0, value) / 1_000_000)
    }
}
