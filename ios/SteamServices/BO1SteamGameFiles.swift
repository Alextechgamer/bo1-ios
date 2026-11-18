// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO1 iOS contributors
import SwiftUI
import UIKit

@MainActor
private final class BO1DownloadBackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}

@MainActor
@objc(BO1SteamGameFiles)
final class BO1SteamGameFiles: NSObject {
    private static var controllers: [UUID: BO1GameFilesCoordinator] = [:]

    @objc(makeViewControllerForDirectory:completion:)
    static func makeViewController(forDirectory directory: URL,
                                   completion: @escaping (NSError?) -> Void) -> UIViewController {
        let id = UUID()
        let model = BO1GameFilesCoordinator(directory: directory)
        let controller = UIHostingController(rootView: BO1GameFilesView(model: model))
        controller.modalPresentationStyle = .formSheet
        // Visible Done/Cancel controls own dismissal. This also avoids a swipe
        // racing a new write immediately after SwiftUI updates its busy state.
        controller.isModalInPresentation = true
        controllers[id] = model
        model.closeRequested = { [weak model] cancelled in
            guard let model else { return }
            Task { @MainActor in
                await model.cancelAndWait(closing: true)
                model.closeRequested = nil
                controllers[id] = nil
                let error = cancelled ? NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                    userInfo: [NSLocalizedDescriptionKey: "Game Files was cancelled after its writes stopped."]) : model.completionError
                // The caller owns presentation/dismissal and can now recheck
                // the game folder. Factory creation never calls completion.
                completion(error)
            }
        }
        return controller
    }

    @objc static func applicationDidEnterBackground() {
        for model in controllers.values {
            // Do not cancel SteamSignInModel: Steam Guard/QR approval may be on
            // the Steam app. Only this coordinator's content operations stop.
            let lifetime = BO1DownloadBackgroundTask()
            lifetime.identifier = UIApplication.shared.beginBackgroundTask(withName: "Pause Black Ops download") { [weak model, lifetime] in
                // UIKit invokes expiration on the main thread. Return the
                // background-task assertion immediately; a suspended rollback
                // is recoverable from its journal when the app runs again.
                model?.pause()
                lifetime.end()
            }
            Task { @MainActor in
                await model.pauseForBackground()
                lifetime.end()
            }
        }
    }
}
