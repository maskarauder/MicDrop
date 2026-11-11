// Open-source notices sheet (`MainActivity.kt:520-530`).
//
// The text is every bundled notice file in `OpenSourceNotices.resourceNames` order (`NOTICE`, `LICENSE`,
// `ios-notices.txt`, `webrtc-notice.txt`) joined with "\n\n", loaded off the main thread (the WebRTC NOTICE is large).
// A missing or unreadable resource shows `OpenSourceNotices.unavailableText`. The text is scrollable, selectable and
// monospaced, shown in a UITextView (SwiftUI `Text` lays out very large strings slowly), with an OK control.

import MicDropCore
import SwiftUI
import UIKit

struct NoticesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    private let load: @Sendable () async -> String

    /// `load` defaults to the bundled resources; tests and previews inject text.
    init(load: @escaping @Sendable () async -> String = { await NoticesView.loadBundled() }) {
        self.load = load
    }

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    NoticesTextView(text: text)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle(OpenSourceNotices.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.ok) { dismiss() }
                }
            }
        }
        .task {
            if text == nil { text = await load() }
        }
    }

    /// Reads the bundled notices on a background task ("Load the text off the main thread").
    nonisolated static func loadBundled() async -> String {
        await Task.detached(priority: .userInitiated) {
            NoticesView.combinedText(bundle: Bundle.main)
        }.value
    }

    /// `OpenSourceNotices.combined` over `bundle.url(forResource:withExtension: nil)`; any missing or
    /// unreadable file → `OpenSourceNotices.unavailableText`.
    nonisolated static func combinedText(bundle: Bundle) -> String {
        do {
            return try OpenSourceNotices.combined { name in
                guard let url = bundle.url(forResource: name, withExtension: nil) else {
                    throw NoticeResourceMissing(name: name)
                }
                return try String(contentsOf: url, encoding: .utf8)
            }
        } catch {
            return OpenSourceNotices.unavailableText
        }
    }

    /// A notice resource is not in the bundle (unreachable in CI builds: `tools/check_ios_bundle.py`).
    private struct NoticeResourceMissing: Error {
        let name: String
    }
}

/// Read-only, selectable monospaced text (Dynamic Type scaled), 16 pt insets.
private struct NoticesTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textColor = .label
        let base = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
