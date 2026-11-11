# Windows microphone return

MicDrop sends the phone microphone to a selected Windows **playback/render**
endpoint. A separately installed virtual audio cable exposes the received audio
through its paired **recording** endpoint to voice or recording applications.
MicDrop does not install or bundle a driver.

1. Install a suitable cable from its vendor, following its instructions and
   license terms. Existing users can keep their installed cable.
2. With the Windows host stopped, select the cable's playback endpoint under
   MicDrop's **Audio** settings, enable microphone return, and start the host.
3. In the receiving Windows app, select the cable's recording endpoint as input.
   For VB-CABLE these are **CABLE Input** and **CABLE Output**, respectively.
4. On the phone (Android or iPhone), choose the intended microphone, enable
   **Send microphone**, grant permission, and Connect. Also enable **Play desktop
   audio** for duplex.
5. Test a short private recording. Check that mute and Stop silence the input.
   Use headphones and leave Windows **Listen to this device**/input monitoring
   off to avoid feeding the microphone back into desktop playback.

Keep Windows and the phone app on matching builds. A missing or disabled selected
endpoint must fail explicitly; MicDrop does not substitute the desktop speakers.
The cable's buffer and the receiving application's processing affect delay.
Network statistics alone cannot establish end-to-end microphone latency.

Developers can test the endpoint independently with `windows-host.exe
bridge-devices` and `bridge-check --render-device <id> --duration 10s` from the
development harness, which sends a quiet synthetic test signal through the
selected cable endpoint. Those tools are not required by beta testers.
