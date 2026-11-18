// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO1 iOS contributors
import Foundation

enum BO1DownloadError: LocalizedError {
    case invalid(String)
    case accountChanged
    case recoveryRequired
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .accountChanged: return "The Steam account changed. The download was stopped. Refresh the account's packages before continuing."
        case .recoveryRequired: return "Publishing was interrupted and automatic recovery needs attention. The game remains blocked from starting. Open Game Files again to retry recovery."
        }
    }
}

enum BO1DLC: UInt32, CaseIterable, Identifiable, Codable, Sendable {
    case firstStrike = 42716, escalation = 42718, annihilation = 42722, rezurrection = 42719
    var id: UInt32 { rawValue }
    var name: String {
        switch self {
        case .firstStrike: return "First Strike"
        case .escalation: return "Escalation"
        case .annihilation: return "Annihilation"
        case .rezurrection: return "Rezurrection"
        }
    }
}

struct BO1PackageSelection: Equatable, Codable, Sendable {
    var language = "english"
    var multiplayer = false
    var dlcAppIDs = Set<UInt32>()
}

/// Metadata projection only. The production adapter creates this from current
/// signed-in PICS responses; this is not a replacement manifest/depot table.
struct BO1DepotMetadata: Equatable, Sendable {
    var id: UInt32
    var manifest: UInt64?
    var language = ""
    var oslist = ""
    var arch = ""
    var dlcAppID: UInt32?
    var fromApp: UInt32?
    var sharedInstall = false
    var lowViolence = false
    var downloadBytes: UInt64 = 0
    var diskBytes: UInt64 = 0

    var supportsBO1: Bool {
        (oslist.isEmpty || oslist.lowercased().split(separator: ",").contains("windows")) &&
            (arch.isEmpty || arch == "32") && !sharedInstall && !lowViolence
    }
    func matches(language selected: String) -> Bool {
        language.isEmpty || language.caseInsensitiveCompare(selected) == .orderedSame
    }
}

struct BO1AppMetadata: Sendable {
    var id: UInt32
    var name: String
    var depots: [BO1DepotMetadata]
}

struct BO1InstallStep: Equatable, Sendable {
    var appID: UInt32
    var title: String
    var depotIDs: [UInt32]
    var manifests: [UInt64]
    var downloadBytes: UInt64
    var diskBytes: UInt64
}

struct BO1InstallPlan: Equatable, Sendable {
    var selection: BO1PackageSelection
    var steps: [BO1InstallStep]
    var fingerprint: String {
        selection.language.lowercased() + "|" + steps.map { step in
            "\(step.appID):" + zip(step.depotIDs, step.manifests).map { pair in "\(pair.0)=\(pair.1)" }.joined(separator: ",")
        }.joined(separator: "|")
    }
    var estimatedDownloadBytes: UInt64 { steps.reduce(0) { BO1InstallSelection.add($0, $1.downloadBytes) } }
    var estimatedDiskBytes: UInt64 { steps.reduce(0) { BO1InstallSelection.add($0, $1.diskBytes) } }
}

enum BO1InstallSelection {
    static let baseApp: UInt32 = 42700
    static let multiplayerApp: UInt32 = 42710

    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    static func languages(in apps: [UInt32: BO1AppMetadata], multiplayer: Bool) -> [String] {
        let ids = multiplayer ? [baseApp, multiplayerApp] : [baseApp]
        var choices: Set<String>?
        for id in ids {
            guard let app = apps[id] else { continue }
            let published = Set(app.depots.filter { $0.supportsBO1 && $0.dlcAppID == nil && !$0.language.isEmpty }
                .map { $0.language.lowercased() })
            // An app with common-only content does not restrict the language.
            if !published.isEmpty { choices = choices.map { $0.intersection(published) } ?? published }
        }
        return (choices ?? ["english"]).sorted { a, b in
            if a == "english" { return b != "english" }
            if b == "english" { return false }
            return a < b
        }
    }

    static func makePlan(selection: BO1PackageSelection, apps: [UInt32: BO1AppMetadata],
                         ownedApps: Set<UInt32>) throws -> BO1InstallPlan {
        guard ownedApps.contains(baseApp) else {
            throw BO1DownloadError.invalid("This Steam account does not list Call of Duty: Black Ops (42700). Campaign and Zombies require that game.")
        }
        let language = selection.language.lowercased()
        guard !language.isEmpty, language.utf8.count <= 40,
              language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }),
              languages(in: apps, multiplayer: selection.multiplayer).contains(language) else {
            throw BO1DownloadError.invalid("Steam did not publish the selected language for these base packages. Choose another available language.")
        }
        if selection.multiplayer && !ownedApps.contains(multiplayerApp) {
            throw BO1DownloadError.invalid("Multiplayer is not included in this account's Steam licenses.")
        }
        let knownDLC = Set(BO1DLC.allCases.map(\.id))
        guard selection.dlcAppIDs.isSubset(of: knownDLC), selection.dlcAppIDs.isSubset(of: ownedApps) else {
            throw BO1DownloadError.invalid("Only Black Ops DLC owned by the signed-in account can be selected.")
        }
        var grouped: [UInt32: [BO1DepotMetadata]] = [:]
        var titles: [UInt32: String] = [:]
        var order: [UInt32] = []
        var seen: [UInt32: UInt64] = [:]
        func append(_ depots: [BO1DepotMetadata], from appID: UInt32, title: String) throws {
            guard !depots.isEmpty else { throw BO1DownloadError.invalid("Steam supplied no compatible public content for \(title) in \(language).") }
            if grouped[appID] == nil { grouped[appID] = []; titles[appID] = title; order.append(appID) }
            for depot in depots {
                guard let manifest = depot.manifest, manifest != 0 else {
                    throw BO1DownloadError.invalid("Steam did not resolve a public manifest for a selected depot. Refresh the package list and retry.")
                }
                if let prior = seen[depot.id] {
                    guard prior == manifest else { throw BO1DownloadError.invalid("Selected packages reference conflicting versions of the same depot.") }
                    continue
                }
                seen[depot.id] = manifest
                grouped[appID, default: []].append(depot)
            }
        }
        for id in selection.multiplayer ? [baseApp, multiplayerApp] : [baseApp] {
            guard let app = apps[id] else { throw BO1DownloadError.invalid("Steam did not return the required Black Ops package metadata.") }
            let depots = app.depots.filter {
                $0.supportsBO1 && $0.matches(language: language) && $0.dlcAppID == nil &&
                    !knownDLC.contains($0.fromApp ?? 0)
            }
            try append(depots, from: id, title: id == baseApp ? "Campaign and Zombies" : "Multiplayer / Combat Training")
        }
        for dlc in BO1DLC.allCases where selection.dlcAppIDs.contains(dlc.id) {
            // Some Steam DLC apps describe their depots directly; others attach
            // them to a parent via dlcappid. Only explicit relationships qualify.
            let direct = apps[dlc.id]?.depots.filter {
                $0.supportsBO1 && $0.matches(language: language) && ($0.dlcAppID == nil || $0.dlcAppID == dlc.id)
            } ?? []
            var found = false
            if !direct.isEmpty { try append(direct, from: dlc.id, title: dlc.name); found = true }
            let parents = selection.multiplayer ? [baseApp, multiplayerApp] : [baseApp]
            for id in parents where ownedApps.contains(id) {
                let matching = apps[id]?.depots.filter {
                    $0.supportsBO1 && $0.matches(language: language) &&
                        ($0.dlcAppID == dlc.id || $0.fromApp == dlc.id)
                } ?? []
                if !matching.isEmpty { try append(matching, from: id, title: dlc.name); found = true }
            }
            guard found else {
                throw BO1DownloadError.invalid("Steam lists \(dlc.name) as owned, but did not provide a matching Windows depot relationship. It was not guessed or downloaded.")
            }
        }
        let steps = order.compactMap { id -> BO1InstallStep? in
            guard let depots = grouped[id], !depots.isEmpty else { return nil }
            let sorted = depots.sorted { $0.id < $1.id }
            return BO1InstallStep(appID: id, title: titles[id] ?? "Black Ops content", depotIDs: sorted.map(\.id),
                manifests: sorted.compactMap(\.manifest),
                downloadBytes: sorted.reduce(0) { add($0, $1.downloadBytes) },
                diskBytes: sorted.reduce(0) { add($0, $1.diskBytes) })
        }
        guard !steps.isEmpty else { throw BO1DownloadError.invalid("No installable Black Ops content was selected.") }
        return BO1InstallPlan(selection: selection, steps: steps)
    }
}
