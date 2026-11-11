import Foundation

/// The `X-MicDrop-Session-Resume` and `X-MicDrop-Session-Resume-Reason` hints (`A/SessionResume.kt`; host
/// `internal/session/resume.go`).
///
/// A presentation hint for the authenticated Windows host: an intentional Play/focus resume or input-switch
/// replacement of the same phone is shown with its specific cause instead of as a new connection. It grants no
/// capture consent and carries no session capability. Only Play/focus-resume and the input-switch replacement set it;
/// explicit Connect/Reconnect, including after Stop while paused, sends none. The host accepts at most one value on a
/// paired v3 `/offer` and answers anything else with 400 before allocating media (`host.go:170-174`), so the version
/// and path gate is mandatory.
public enum SessionResume {
    public static let header = "X-MicDrop-Session-Resume"
    public static let reasonHeader = "X-MicDrop-Session-Resume-Reason"
    public static let value = "1"

    /// Cause of a resumed `/offer` (`A/SessionResume.kt:13`): `manual` is any Play/Resume command (accessory or system
    /// Play cannot be told apart), `focusRegain` is an interruption focus return, and `automatic` is a phone-initiated
    /// replacement with neither (the live microphone input switch).
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case manual = "manual"
        case automatic = "automatic"
        case focusRegain = "focus_regain"

        public var wire: String { rawValue }
    }

    /// The live microphone input-switch replacement (`A/SessionResume.kt:14`).
    public static let inputSwitch: Reason = .automatic

    /// `manual` for a user/media Play or Resume command, `focusRegain` for an automatic focus return
    /// (`A/SessionResume.kt:15`).
    public static func resumed(userRequested: Bool) -> Reason {
        userRequested ? .manual : .focusRegain
    }

    /// `"1"` iff `version == 3 && path == "/offer" && resume != nil`, else nil (`A/SessionResume.kt:16-17`).
    public static func offerHeader(version: Int, path: String, resume: Reason?) -> String? {
        version == 3 && path == ControlRequest.Path.offer && resume != nil ? value : nil
    }

    /// `resume.wire` iff `offerHeader(version:path:resume:) != nil`, else nil (`A/SessionResume.kt:18-19`).
    public static func reasonHeader(version: Int, path: String, resume: Reason?) -> String? {
        offerHeader(version: version, path: path, resume: resume) != nil ? resume?.wire : nil
    }

    /// Both resume headers in wire order (`[(header, "1"), (reasonHeader, resume.wire)]`) for a resuming v3 `/offer`,
    /// or `[]` (`A/SessionResume.kt:21-23`).
    public static func offerHeaders(version: Int, path: String, resume: Reason?) -> [(String, String)] {
        guard let hint = offerHeader(version: version, path: path, resume: resume),
            let reason = reasonHeader(version: version, path: path, resume: resume)
        else { return [] }
        return [(header, hint), (reasonHeader, reason)]
    }
}
