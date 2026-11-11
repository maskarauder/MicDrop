import Foundation

/// The `audio.output` field of phone settings exchange v1 on the iPhone (D046; of 2026-10-27, the Android counterpart
/// planned beside `A/AppPhoneControl.kt:113-161`). Pure rules over `OutputChoice` and `OutputSelection`, so they run in
/// the portable tests; `PhoneControlAdapter` supplies the session's output, the current-route list and its salted
/// choice tokens, and routes the command.
///
/// - A session that plays desktop audio through a media output (`StreamMode.usesMediaOutput`: playback, or duplex
///   with a phone, wired or USB microphone) applies a Windows choice at once (`effect: live`) through its
///   controller's own verified in-session switch (`setOutputSelection`, the phone's output chooser). That switch
///   keeps playback gated until the new route verifies, ends the session if it never does, and saves the choice like
///   a local one, so later Pause/Play, duplex resumes and input switches pass their output preflight. There is no
///   reconnect: every offered output is in the current route or a pinnable speaker.
/// - A duplex session with a Bluetooth headset microphone hands the choice to its controller too, which keeps it for
///   a later switch to a phone, wired or USB microphone without changing the headset route (the phone's "Media
///   output after headset mic"), so the field stays `next_connection` there.
/// - A microphone-only session has no output, and the choice is saved for the next connection.
public enum PhoneOutputControl {
    /// Suffixes of an entry that is not in the current-route list: Android's saved entry (`A/AppPhoneControl.kt:108,
    /// 117`) and the iPhone's in-use entry.
    public static let savedSuffix = " (saved)"
    public static let savedUnavailableSuffix = " (saved; unavailable)"
    public static let inUseSuffix = " (in use)"

    /// One `audio.output` choice: its opaque token, the selection it names and its snapshot label.
    public struct Entry: Equatable, Sendable {
        public let token: String
        public let selection: OutputSelection
        public let label: String

        public init(token: String, selection: OutputSelection, label: String) {
            self.token = token
            self.selection = selection
            self.label = label
        }
    }

    /// The field's `effect`: `live` while a Windows choice switches the running route (`appliesLive`), otherwise
    /// `next_connection`. It can flip within one session (an input switch to or from a Bluetooth headset microphone);
    /// the revision covers it, so a stale Windows editor reloads.
    public static func effect(appliesLive: Bool) -> PhoneSetting.Effect {
        appliesLive ? .live : .nextConnection
    }

    /// An output the next Connect can restore (`AudioPreferencesStore.restoredOutputSelection`): iPhone media output,
    /// the permanent iPhone speaker pin or an external output with a remembered identity
    /// (`RememberedAudioDevices.rememberable`). Never wired headphones, which iOS gives one port-wide uid, so a saved
    /// choice of them would restore iPhone media output and fail the next Connect with `output_reselect`, and never the
    /// temporary iPhone speaker, which is saved as iPhone media output (`OutputSelection.preferenceKind`) and is set
    /// only by the phone's own **Use iPhone speaker**.
    public static func savable(_ selection: OutputSelection) -> Bool {
        !selection.explicit || (selection.kind == .phone && !selection.temporarySpeaker)
            || RememberedAudioDevices.rememberable(output: selection) != nil
    }

    /// The field's value and choices, at most `maxListed + 1` (Go allows 32):
    /// 1. the `savable` choices of `route` (`OutputChoices.choices()`), at most `maxListed`, in list order;
    /// 2. the base selection, appended when its token is not listed: the session's output when there is one
    ///    (`session`), else the saved output (`saved`). A session output that is not `savable` (wired headphones, or
    ///    the temporary iPhone speaker) gets its title in `route`, else its kind label, followed by `" (in use)"`, so
    ///    Windows shows the output the session really uses and the value stays one of the choices (Go
    ///    `Validate`); `apply` rejects it through `savable`. Any other base reads `"<kind> (saved)"` while
    ///    `available`, else `"<kind> (saved; unavailable)"` (`A/AppPhoneControl.kt:113-120`).
    ///
    /// With a session output the saved output is not added: the field shows and changes that session's output, which
    /// its controller saves like a local choice, so the two agree. The value is the base's token. A repeated token
    /// (the same identity) keeps its first entry.
    public static func choices(
        route: [OutputChoice], session: OutputSelection?, saved: OutputSelection, maxListed: Int,
        available: (OutputSelection) -> Bool, token: (OutputSelection) -> String
    ) -> (value: String, entries: [Entry]) {
        let base = session ?? saved
        let baseToken = token(base)
        var entries: [Entry] = []
        var listed = Set<String>()
        func add(_ selection: OutputSelection, _ title: String, _ value: String) {
            guard listed.insert(value).inserted else { return }
            entries.append(Entry(token: value, selection: selection, label: PhoneControl.label(title)))
        }
        for choice in route.filter({ savable($0.selection) }).prefix(max(0, maxListed)) {
            add(choice.selection, choice.title, token(choice.selection))
        }
        if !listed.contains(baseToken) {
            let title: String
            if session != nil && !savable(base) {
                let shown = route.first { token($0.selection) == baseToken }?.title ?? base.kind.label
                title = shown + inUseSuffix
            } else {
                title = base.kind.label + (available(base) ? savedSuffix : savedUnavailableSuffix)
            }
            add(base, title, baseToken)
        }
        return (baseToken, entries)
    }
}
