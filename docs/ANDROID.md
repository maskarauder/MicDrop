# Android app

Use the [beta guide](BETA_TESTING.md) for installation, pairing, background
battery settings, and testing. Android 12/API 31+ on arm64 is supported. The
current APK uses `com.maskarauder.micdrop.dev` and a stable development signer;
it is not a Play Store release. Use a matching Windows candidate.

## Connection and audio

Select a paired Windows host or scan/paste a private pairing invitation. Choose
**Play desktop audio**, **Send microphone**, or both, then **Connect**. Windows
must approve new pairings. Discovery locates hosts; it does not establish trust
or start audio. Camera permission is optional when using a pasted invitation.

Choose the intended output and microphone input before connecting. Microphone
permission is requested for microphone use; playback alone does not need it.
Windows must have microphone return enabled with a suitable
[virtual cable](VIRTUAL_AUDIO_CABLE.md). No unavailable microphone is silently
replaced by a different source.

During a session, the microphone checkbox mutes/unmutes an already authorized
microphone. Pause/resume and Stop are available through the app and notification.
Notification Play is playback-only; it cannot silently start a new microphone
session. Play, **Resume duplex**, a returned audio focus and a microphone input
switch tell a current Windows build why the same phone is resuming, so its
status reads accordingly without a second connected notice (see the
[Windows desktop guide](WINDOWS_DESKTOP.md#host-ownership-and-settings)). Live media-output changes and microphone replacement have different
route/reconnect behavior; observe the reported effective route before testing.

Bluetooth media and communication routes have different limits. Classic headset
microphone use commonly switches playback to voice quality. LE Audio, hearing
aids, wired and USB routes require device-specific testing; an available picker
entry is not proof of stereo duplex or low latency. Mark unavailable hardware
checks skipped with a reason.

## Settings and diagnostics

[Advanced settings](ADVANCED_SETTINGS.md) covers remote/LAN ordering, timeouts,
microphone processing, and Windows control permission. Most connection settings
are saved for the next explicit Stop/Connect. Windows-originated changes require
the phone's **Allow Windows to change phone settings** opt-in. Neither Windows
nor saved preferences can grant Android permissions.

With the opt-in on, Windows may change the settings the app advertises, one
command at a time. Windows is offered Unmute only after this phone opened
capture in the session and while microphone (and, for a Bluetooth input,
Bluetooth) permission is granted; a Mute tapped while connecting withholds it
until one unmute on the phone. A Windows Unmute or **Play desktop audio**
change lasts only for the current session, while a Windows Mute is saved like
the phone's own. **Keep microphone capture active while muted** is read once at
the explicit Connect, so a Windows edit waits for the next Connect. A Windows
media-output choice applies at once during playback and during duplex with the
phone, wired or USB microphone, through the same verified switch as the app's
own chooser; with a Bluetooth headset microphone it is held and saved for a
later switch to another input, and in a microphone-only session it is saved for
the next Connect. Details and the Windows editor's messages are in the
[phone settings exchange](PHONE_CONTROL_V1.md) and the
[Windows desktop guide](WINDOWS_DESKTOP.md#persistent-device-status-and-phone-settings).

**Diagnostics** contains the last stream report, crash report, local output
check, and open-source notices. The output check tests Android playback without
a Windows connection. RTT/jitter/buffer counters do not measure physical latency.
Before Windows returns a 200 `/offer` body, the report labels the deadlines and
media recovery `not negotiated (no Windows offer reply)` and the terminal
diagnostics `not sent; no Windows offer reply` rather than legacy or
unsupported; see
[Advanced settings](ADVANCED_SETTINGS.md#windows-coordination).
Keep reports private and review them before sharing.

In-place updates require the same application ID and signing certificate.
Uninstalling removes app data and pairing. If Android reports a signature
conflict, contact the maintainer before uninstalling. See
[Development](DEVELOPMENT.md#android-app) for source builds and ADB installation.
