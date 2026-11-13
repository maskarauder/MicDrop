# Desktop microphone return (virtual audio cable)

MicDrop sends the phone microphone to an explicitly selected desktop
**playback/render** endpoint. A separately configured virtual audio cable or
sink exposes the received audio through its paired **recording** endpoint to
voice, chat, or recording applications. MicDrop does not install or bundle a
kernel audio driver.

## Platform setup

### Windows 11

1. Install a suitable virtual audio cable from its vendor (for example,
   VB-CABLE), following its instructions and license terms. Existing users can
   keep their installed cable.
2. With the MicDrop host stopped, select the cable's playback endpoint under
   **Audio** (for VB-CABLE, **CABLE Input**), save, and start the host.
3. In the receiving Windows app, select the cable's recording endpoint as input
   (for VB-CABLE, **CABLE Output**). Leave Windows **Listen to this device** /
   input monitoring off so microphone audio does not feed back into desktop
   playback.

### Linux (PipeWire / PulseAudio)

1. Create a dedicated user-space null sink and remapped virtual microphone
   source (no root privileges or kernel module required):
   ```sh
   pactl load-module module-null-sink sink_name=MicDropCable rate=48000 channels=2 \
     sink_properties=device.description=MicDrop_Cable
   pactl load-module module-remap-source source_name=MicDropVirtualMic \
     master=MicDropCable.monitor source_properties=device.description=MicDrop_Virtual_Mic
   ```
2. With the MicDrop host stopped, click **Refresh audio**, select
   **MicDrop\_Cable** under *Virtual cable output for phone mic*, save, and
   start the host.
3. Select **MicDrop\_Virtual\_Mic** as the microphone input inside your voice or
   recording application. See [Linux desktop](LINUX_DESKTOP.md#virtual-microphone-setup-pipewire--pulseaudio)
   and [platform audio](PLATFORM_AUDIO.md#linux-host) for persistent setup.

### macOS 14.2+ (Apple Silicon)

1. Install a user-space CoreAudio HAL virtual cable (such as BlackHole 2ch)
   following its project instructions and license terms.
2. With `MicDrop.app` stopped, click **Refresh audio**, select **BlackHole 2ch**
   under *Virtual cable output for phone mic*, save, and start the host. Keep
   your normal headphones or speakers—not BlackHole—selected as your macOS
   system output so phone mic audio is not mixed back into desktop playback.
3. Select **BlackHole 2ch** as the microphone input inside your voice or
   recording application. See [macOS desktop](MACOS_DESKTOP.md) and
   [platform audio](PLATFORM_AUDIO.md#macos-host).

## Connecting from the phone

1. On the phone (Android or iPhone), choose the intended microphone, enable
   **Send microphone**, grant microphone permission, and tap **Connect**. Also
   enable **Play desktop audio** for two-way duplex.
2. Test a short private recording. Check that **Mute** and **Stop** silence the
   receiving desktop application, and wear headphones during duplex sessions to
   prevent acoustic feedback.

Keep the desktop host and phone app on matching builds. A missing or disabled
selected virtual cable endpoint fails closed explicitly; MicDrop never
substitutes the desktop speakers. The cable's buffer and the receiving
application's processing affect delay; network statistics alone cannot establish
end-to-end microphone latency.

Developers can test a render endpoint independently with `windows-host.exe` or
`micdrop-host` (`bridge-devices` and `bridge-check --render-device <id> --duration 10s`),
which sends a quiet synthetic test signal through the selected cable endpoint
without activating phone capture.
