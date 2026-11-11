// In-app replacement for Android `Toast` (`MainActivity.kt:999-1003`, `:554`).

import Observation
import SwiftUI
import UIKit

/// One transient notice at a time. Showing replaces (cancels) the current one; nothing is shown while
/// the scene is in the background, and entering the background cancels the current toast. Every
/// toast is also announced to VoiceOver.
@MainActor
@Observable
final class ToastCenter {
    /// Android `LENGTH_SHORT` (2.0 s) / `LENGTH_LONG` (3.5 s).
    enum Length: Equatable, Sendable {
        case short
        case long

        var duration: Duration {
            switch self {
            case .short: return .milliseconds(2_000)
            case .long: return .milliseconds(3_500)
            }
        }
    }

    struct Toast: Identifiable, Equatable, Sendable {
        let id: UInt64
        let text: String
        let length: Length
    }

    /// The toast on screen, if any.
    private(set) var current: Toast?

    @ObservationIgnored private var serial: UInt64 = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var visible = true
    private let announce: @MainActor (String) -> Void

    /// `announce` defaults to a VoiceOver announcement (`UIAccessibility.post(.announcement)`).
    init(
        announce: @escaping @MainActor (String) -> Void = {
            UIAccessibility.post(notification: .announcement, argument: $0)
        }
    ) {
        self.announce = announce
    }

    /// Shows `text`, replacing any current toast. Ignored while the scene is in the background.
    func show(_ text: String, length: Length = .short) {
        guard visible else { return }
        hideTask?.cancel()
        serial &+= 1
        let toast = Toast(id: serial, text: text, length: length)
        current = toast
        announce(text)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: length.duration)
            guard !Task.isCancelled, let self, self.current?.id == toast.id else { return }
            self.current = nil
        }
    }

    /// Removes the current toast.
    func cancel() {
        hideTask?.cancel()
        hideTask = nil
        current = nil
    }

    /// Scene visibility (`scenePhase != .background`). Hiding cancels the current toast
    /// (Android `onStop` cancels the connection toast).
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible { cancel() }
    }
}

/// The capsule shown above the action bar (surface background, border, primary text).
struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        ZStack {
            if let toast = center.current {
                Text(toast.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().stroke(Theme.surfaceBorder, lineWidth: 1))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .id(toast.id)
                    // Already announced by ToastCenter; avoid a second VoiceOver focus target.
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current)
        .allowsHitTesting(false)
    }
}
