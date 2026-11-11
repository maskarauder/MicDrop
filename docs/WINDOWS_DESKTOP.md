# Windows desktop app

The desktop host supports Windows 11 x64. For installation, upgrades and removal,
see the [installer guide](WINDOWS_INSTALLER.md). Use the [beta guide](BETA_TESTING.md)
for a first Windows/Android session.

## Start without a console

1. Install MicDrop or extract the complete portable ZIP into a fresh folder. Keep
   `MicDrop.exe`, `micdrop_rtc.dll` and the notices together.
   Stop the old command-line listener with `quit` before starting the desktop
   host. Only one paired listener may own the existing identity store.
2. Double-click **MicDrop.exe**. Under **Audio**, choose the Windows output to
   capture. The default option resolves the default output at each session start.
   Leave microphone return disabled for playback only, or explicitly select the
   virtual cable's playback endpoint (usually **CABLE Input**) for microphone/
   duplex. The receiving Windows app uses **CABLE Output**. MicDrop neither
   installs nor bundles a virtual audio driver.
3. Under **Connection**, select the physical home-LAN adapter and its private
   IPv4 address. Adapter names and current addresses are shown, including virtual
   adapters; MicDrop does not guess which one is your home network. Save and
   **Start host**. When Windows requests firewall access, allow your trusted
   **Private** network. An old rule scoped to `windows-host.exe` does not cover
   `MicDrop.exe`; **Windows Firewall…** opens Windows' own settings if needed.
4. For an already paired phone, connect normally. The desktop app uses the same
   current-user DPAPI identity, approved-phone database and remote configuration
   as the CLI. There is no forced reset or re-pairing.
5. For a new phone, open **Phones → Pair a phone**, scan the private QR and tap
   Connect on Android. Compare the request ID before approving it on Windows;
   the supplied phone name is unverified. The copied link is private and goes to
   the Windows clipboard only when **Copy pairing link** is explicitly clicked.

The UI is native Win32, with dark slate (`#202831`) and gold (`#D4AC45`) accents,
standard Windows control behavior/application icon and a text wordmark. Buttons,
device lists and option controls use flat slate surfaces with black text, including
locked controls; gold marks selection, press and focus. The title bar follows the
slate palette where Windows supports caption colors. No generated art or custom
logo is included. Native keyboard navigation and per-monitor DPI
scaling are enabled; Windows high-contrast colors take priority.

## Host ownership and settings

**Start host** opens the paired listener. It does not itself start desktop or
microphone capture. The phone still authorizes a session and chooses its modes.
**Stop host** stops media and closes listeners; Start stays disabled until cleanup
releases ownership. Changes to audio/network/remote choices require stopping the
host. **Exit** waits for that same cleanup. Closing the window keeps the tray app
running; if the tray is unavailable, closing stops and exits rather than hiding
an inaccessible process. Starting a second desktop instance opens the first.

**Options → Start host when I sign in** is opt-in and uses only the current user's Windows
Run entry. It saves the chosen settings, launches in the notification area and
starts the paired listener. There is no pre-login machine service or routine
administrator requirement. If settings/devices/network are unavailable, the
window exposes the error; it does not silently select another device or adapter.
Re-enable startup after deliberately moving the application folder. The desktop
app and development CLI should not run simultaneously with the same identity store.

Settings live in `%LOCALAPPDATA%\MicDrop\desktop-v1.json`; combined session logs
live in `%LOCALAPPDATA%\MicDrop\logs`. **Open logs** opens that folder. Existing
CLI logs in `diagnostics-private` are left in place.

**Options → Save connection logs** enables/disables new combined session files.
**Keep newest connection logs** accepts 1–10000; 0 keeps all and is the default
for existing settings. A positive limit deletes the oldest recognizable MicDrop session
files when the host starts and as sessions change. Active logs are protected and
may temporarily exceed the limit. Turning logging off keeps existing files and
skips pruning. Save changes with the host stopped; they apply on the next Start.
A recovery belongs to the same connection log, while an explicit new connection
creates another. The CLI supports `--log-retention N` and `--no-log`.
 Identity and remote secrets
remain in the existing DPAPI-protected `identity` subfolder. Desktop preferences
contain no credentials or invitations. Invalid/newer settings are reported and
left intact instead of being overwritten with defaults.

The selected adapter is resolved again at each host start. A changed DHCP
address on that same adapter is accepted when unambiguous; another adapter is
never substituted. If the adapter has several new addresses, refresh and select
one explicitly. Address changes during a running listener still require Stop,
Refresh network and Start; refresh a phone invitation if its saved address needs
updating. The listener does not migrate automatically while running.

Saved explicit audio endpoints are retained when absent and reported unavailable.
There is no fallback to another output or cable. The desktop path also checks
for capture/return using the same endpoint, including the current default, before
session creation. A default-output change during already active capture retains
the engine's existing behavior; it is not a new live device-switch feature.

Intentional phone Pause and audio-focus interruptions do not raise a Windows
connection-failure notification. A matching updated phone app also identifies
Play/resume, so the same phone resumes without another Connected notification.
The resume is quiet only for the same authenticated phone whose previous
connected session ended with `receiver_pause`, `receiver_focus_lost_transient`,
`receiver_focus_lost_permanent` or the older `receiver_focus_lost` (the wire
`focus_loss` of a phone without lifecycle version 2). The status text follows
the phone's optional resume reason (see [the protocol](PROTOCOL.md#legacy-diagnostic-lan-protocol-version-2)):
no reason, `manual` or an unknown token shows "Resuming the phone connection…";
`focus_regain` shows "The phone's audio interruption ended. Resuming…";
`automatic` shows "The phone is reconnecting to apply a change…". No text
claims that a person pressed Play, because accessory and system Play also
arrive as `manual`. A microphone input switch on a current phone ends the old
session as a pause, so the row briefly shows "Paused on the phone. Tap Play on
the phone to resume.", then the reconnecting text, and no Phone connected
notice. Connect after Stop (also while paused), a different or unidentified
phone, a first connection after pausing during setup, an ordinary Stop or
failure, and a host restart show "Connecting to the phone…" and notify Phone
connected regardless of any reason. Explicit Stop followed by Connect is a new
connection and still notifies. A later in-session network recovery still
notifies Connection restored. Actual connection failures retain their
notifications. A phone that sends no reason gets the generic resuming text; a
Windows build older than the reason header ignores it.

## Persistent device status and phone settings

The header stays visible across Audio, Connection, Phones and Options. It lists
approved phones, counts currently connected streams, and shows the selected
phone's Connecting, Connected, Reconnecting, Paused or Offline state. The list has
room to grow, and the host supports only one active media stream.
Pausing closes the transport; Paused is explicitly a last-reported state rather
than proof the phone is reachable. Settings controls and live statistics are
unavailable until it reconnects. Stale telemetry is never displayed as current.

Statistics are **Network RTT**, **RTP jitter**, **Playback buffer** and an estimated
**Output queue**. None measures physical speaker or microphone delay. Live
statistics continue while Windows file logging is off; the phone reports that
Windows is not recording them.

With matching updated Windows and phone builds, connect the phone and select
its row, then choose **Device settings** (double-clicking the row also opens
the editor). The Live, Audio and Advanced groups display the phone's current
saved preferences and available controls. To permit changes, enable
**Advanced → Allow Windows to change phone settings** on Android (the iPhone
app uses the same **Advanced** location). This is off by default and remains a
phone-local choice; while it is off, the editor's status line reads "On the
phone, enable ‘Allow Windows to change phone settings’ to allow changes here.",
its value controls and **Apply setting** stay disabled, and **Reload** stays
available. The message names the option rather than a settings section because
the section differs between Android and iPhone. While changes are allowed, the
status line reads "Only the selected setting is sent. Microphone consent and
phone permissions stay on the phone." Select a setting, edit its value, and
choose **Apply setting**; wait for the phone's confirmation. An edit that
reaches the host just after the phone turned the option off is refused with
"enable ‘Allow Windows to change phone settings’ on the phone first".

The **Device settings** button is enabled only while the connected phone has a
current settings snapshot; the editor itself says why a phone's settings are
unavailable. A phone that is not connected (paused, interrupted, reconnecting
or offline) shows "Phone settings are available only while this phone is
connected. Resume or reconnect it to make changes." A connected phone whose
MicDrop predates phone settings exchange v1 (no `X-MicDrop-Phone-Control`
header on its offer) shows "This phone's MicDrop version can't share its
settings with Windows. Update MicDrop on the phone, then connect again, to
change its settings here."; such a phone keeps streaming. A connected,
supporting phone that has not sent a current snapshot yet, or whose last
snapshot is older than ten seconds, shows "Waiting for the phone to share its
current settings…".

Live controls adjust Android's media/voice volume, desktop-audio output, and mute
within an already authorized microphone session. Unmute is offered only after
the phone itself enabled capture in that session and while its microphone
permission is granted. Windows Unmute and **Play desktop audio** changes last
only for the current phone session; a Windows Mute is saved like the phone's
own Mute. The phone's media output is a live control in playback sessions and
in duplex with a built-in, wired or USB microphone: the phone switches at once
through its own verified route switch and saves the choice like a local one.
When an input switch changes that effect, the phone's settings revision
changes, so the editor reports "Settings changed or confirmation was not
received. Reload before making another change." and needs **Reload** before
the next edit. Other audio/routing preferences, initial/recovery ordering and
Advanced timeouts are marked for the next connection: save them, then
explicitly Stop and Connect on the phone; the keep-microphone option is read
only at that explicit Connect. Windows cannot grant phone permissions, change
pairing credentials, authorize microphone capture, or start a new microphone
session remotely. An iPhone advertises no volume and no LE Audio stereo
setting (31 of Android's 33); the editor lists only the settings the phone
advertises.

The phone validates every change. If a local edit or reconnect makes the Windows
editor stale, choose **Reload** before trying again. Pending changes are bound to
that device and session, expire without confirmation, and are never queued for
an offline phone or replayed on a later connection. Settings snapshots are not
written to the connection logs. See [the protocol notes](PHONE_CONTROL_V1.md).

## Remote configuration

The existing imported remote configuration is immediately available. Importing
another private JSON configuration uses the same validation and DPAPI storage
as `windows-host remote import`, while the host is stopped. Enable **remote
connections**, save, then start. Importing a file alone does not enable remote
access. Forgetting it keeps device pairings and requires disabling the remote
checkbox for LAN-only use.

The ready status distinguishes a configured remote route from proven reachability.
The desktop app retains the existing LAN/rendezvous and ICE policies; it does not
modify the VPS, bypass TLS or distribute relay credentials in preferences/logs.

## Windows notifications

Enabled by default, with a saved checkbox in Options. Notifications are sent
for actual media-peer connection, pairing approval requests, successful recovery,
unexpected session termination and host startup/runtime failure. Connecting alone
is not a success. Repeated status polls and intermediate recovery failures do not
produce repeated notices; each interrupted episode can produce one restoration
notice. Intentional phone Stop, host Stop, revocation and Exit are quiet.

Notifications contain fixed status text, not pairing links, tokens, fingerprints
or device names. Clicking a notice opens MicDrop; a pending approval opens Phones.
They use the Windows notification area, so Windows notification/quiet-time policy
controls visibility. They do not grant approval, start capture, or promise a
persistent Notification Center history. The icon is restored after Explorer
restarts. Failed tray creation keeps the window accessible.

## Focused checks

Use matching Windows and Android builds. In addition to the table, check quiet
pause/resume versus an explicit new connection, stale settings rejection after
local edits/reconnect, and live statistics with logging disabled. Record actual
hardware and source revision; earlier acceptance is in the validation records.

| Check | Expected result |
| --- | --- |
| Launch and saved paired connection | Select actual adapter/capture/cable once; start without PowerShell; existing phone connects and a single connected notice appears |
| One playback/duplex session | Audio and optional microphone return work through the chosen endpoints; Stop host stops both; restarting permits a fresh connection |
| Pairing and management | One pairing QR/manual link, request-ID confirmation, reject/expired approval cannot authorize; remove a phone requires confirmation and ends its active session |
| Window/tray lifecycle | X hides, tray opens; second launch opens the first; Exit ends the host; no late callback or automatic restart after Stop |
| Preferences and startup | Close/reopen retains choices and pairings; opt in/out of sign-in startup; absent explicit device/adapter shows an error, not a substitute |
| Notifications | One connected notice; one recovery notice if a naturally occurring handoff recovers; unexpected failure alerts; deliberate Stop/Exit quiet; disabling notices is respected |
| Resume text | Play, a returned audio focus and a microphone input switch on the same phone show the resuming, interruption-ended and reconnecting texts above without a second connected notice; Stop then Connect notifies once |
| Presentation | Gold/slate appearance, keyboard navigation, monitor scaling, high contrast and readable QR on the actual Windows desktop |

Automated contracts cover settings preservation, missing/ambiguous adapter and
endpoint handling, default-capture feedback rejection, ownership through cleanup,
stale callbacks/approval expiry and notification transitions. Windows-native
checks create an isolated fake-backend window, exercise real controls/Stop/Exit,
check ABI layouts, and render previews without capturing the user's desktop or
using real phone credentials. They cannot establish audible routing, visible
Windows notifications, or real monitor/accessibility behavior.

## Build

Use the existing Windows Go/MinGW/MSVC setup and build the pinned WebRTC DLL as
in [DEVELOPMENT.md](DEVELOPMENT.md). From the repository root:

```powershell
Push-Location apps/windows-host/resources
try {
    windres desktop.rc -O coff -o ../desktop_windows_amd64.syso
    if ($LASTEXITCODE -ne 0) { throw 'Manifest compilation failed.' }
} finally { Pop-Location }

go build -trimpath -o build/host/ ./apps/windows-host
if ($LASTEXITCODE -ne 0) { throw 'CLI build failed.' }
go build -trimpath -ldflags="-H=windowsgui" -o build/host/MicDrop.exe ./apps/windows-host
if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
```

The internal `windows-x64-harness` artifact includes both executables for CI
and developer diagnostics. The CLI also accepts `windows-host.exe desktop`.
Tester packages contain only the desktop executable and media DLL, plus notices
and current guides. See [installer packaging](WINDOWS_INSTALLER.md) and
[releasing](RELEASING.md). Production signing and automatic updating remain
separate work; first-party licensing is already MPL-2.0.
