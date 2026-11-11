import Foundation

/// Bundled notice files and the text shown under **Open-source notices**.
///
/// Android joins its asset notices with a blank line and shows them in one dialog (`K:MainActivity.kt:520-530`).
/// iOS shows every bundled notice file, in this order. The app's `NoticesView` loads each resource with
/// `Bundle.main.url(forResource:withExtension: nil)` off the main thread and shows `unavailableText` if any
/// resource is missing or unreadable.
public enum OpenSourceNotices {
    /// `NOTICE` and `LICENSE` are MicDrop's own MPL-2.0 notice and license from the repository root (D048,
    /// `docs/LICENSING.md`), first as on Android. `ios-notices.txt` comes from `third_party/ios-assets/`;
    /// `webrtc-notice.txt` is the pinned WebRTC archive's `NOTICE`, installed by `tools/fetch_webrtc.py ios`.
    public static let resourceNames = ["NOTICE", "LICENSE", "ios-notices.txt", "webrtc-notice.txt"]
    /// Dialog title (`strings.xml:81` `notices`).
    public static let title = "Open-source notices"
    public static let unavailableText = "Open-source notices are unavailable in this build."

    /// Loads `resourceNames` in order and joins them with `"\n\n"`; the first loader error propagates.
    public static func combined(_ load: (String) throws -> String) rethrows -> String {
        try resourceNames.map(load).joined(separator: "\n\n")
    }
}
