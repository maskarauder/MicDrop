// Short background-execution window for non-audio phases.
//
// iOS keeps a `UIBackgroundModes=audio` app running only while audio I/O runs; setup (CONNECTING before playout),
// teardown (PAUSING/STOPPING sending `/stop`) and the media-Play saved-link lookup run under
// `UIApplication.beginBackgroundTask` instead of Android's foreground service + wake lock. One lease object per
// controller; it never leaks: `end()` is idempotent and the expiration handler runs `onExpire` and then ends the task
// synchronously.

import Foundation
import UIKit

@MainActor
final class BackgroundExecutionLease {
    /// Lease names (table).
    enum Name {
        static let setup = "MicDrop setup"
        static let teardown = "MicDrop teardown"
    }

    /// Platform hooks (tests inject fakes; production uses `UIApplication.shared`).
    struct Backend {
        /// `beginBackgroundTask(withName:expirationHandler:)`; returns the task identifier raw value,
        /// or nil when iOS refused (`.invalid`).
        var begin: @MainActor (_ name: String, _ expiration: @escaping @MainActor () -> Void) -> Int?
        /// `endBackgroundTask(_:)`.
        var end: @MainActor (_ identifier: Int) -> Void

        init(
            begin: @escaping @MainActor (_ name: String, _ expiration: @escaping @MainActor () -> Void) -> Int?,
            end: @escaping @MainActor (_ identifier: Int) -> Void
        ) {
            self.begin = begin
            self.end = end
        }

        /// `UIApplication.shared` (main actor).
        static var application: Backend {
            Backend(
                begin: { name, expiration in
                    let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                        MainActor.assumeIsolated { expiration() }
                    }
                    return identifier == .invalid ? nil : identifier.rawValue
                },
                end: { identifier in
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
                })
        }
    }

    let name: String
    private let backend: Backend
    private let onExpire: @MainActor () -> Void
    private var identifier: Int?
    /// Bumped on every `begin`, so a late expiration of an ended task is ignored.
    private var generation: UInt64 = 0

    /// - Parameter onExpire: runs on main when iOS expires the task, before the task is ended
    /// (`background_setup_expired` → `receiver.expireBackgroundSetup()` or finish).
    init(name: String, backend: Backend = .application, onExpire: @escaping @MainActor () -> Void) {
        self.name = name
        self.backend = backend
        self.onExpire = onExpire
    }

    /// `true` between a successful `begin()` and `end()` / expiry.
    var isHeld: Bool { identifier != nil }

    /// Begins the background task if not already held. iOS may refuse (no-op then).
    func begin() {
        guard identifier == nil else { return }
        generation &+= 1
        let current = generation
        identifier = backend.begin(name) { [weak self] in
            guard let self, self.generation == current, self.identifier != nil else { return }
            self.onExpire()
            self.end()
        }
    }

    /// Ends the background task if held. Idempotent.
    func end() {
        guard let held = identifier else { return }
        identifier = nil
        backend.end(held)
    }
}
