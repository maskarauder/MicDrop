# Store Publishing Guide (Google Play & Apple App Store)

This document holds the exact build/signing setup, verified copy-paste store metadata, privacy/service declarations, and review notes for publishing **MicDrop** (`com.maskarauder.micdrop`) on **Google Play** and the **Apple iPhone App Store**.

---

## 1. Shared Canonical URLs & Identity

| Field | Value |
| :--- | :--- |
| **Application / Bundle ID** | `com.maskarauder.micdrop` |
| **Privacy Policy URL** | `https://maskarauder.com/micdrop/privacy/` |
| **Support / Marketing URL** | `https://maskarauder.com/micdrop/` |
| **Source Repository** | `https://github.com/maskarauder/MicDrop` |
| **License** | `MPL-2.0` (free, no ads, no subscriptions, no in-app purchases) |

Both the Android app (`Diagnostics → Privacy policy`) and iPhone app (`Diagnostics → Privacy policy`) link directly to `https://maskarauder.com/micdrop/privacy/`.

---

## 2. Google Play Store Setup & Metadata

### 2.1 Generate Upload Keystore & Configure GitHub Secrets

Generate a dedicated Google Play upload keystore locally (keep a backup in your password manager; Play App Signing manages the final distribution key):

```bash
keytool -genkeypair \
  -keystore micdrop-upload.p12 \
  -storetype PKCS12 \
  -alias upload \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=MicDrop Upload, O=Maskarauder, C=US"
```

Add these repository secrets in `maskarauder/MicDrop` (`Settings → Secrets and variables → Actions`):

| Secret Name | Value |
| :--- | :--- |
| `MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64` | `base64 -w0 micdrop-upload.p12` (Linux) or `base64 -i micdrop-upload.p12 \| tr -d '\n'` (macOS) |
| `MICDROP_ANDROID_UPLOAD_STORE_PASSWORD` | Your keystore password |
| `MICDROP_ANDROID_UPLOAD_KEY_ALIAS` | `upload` |
| `MICDROP_ANDROID_UPLOAD_KEY_PASSWORD` | Optional for PKCS12 (defaults to `MICDROP_ANDROID_UPLOAD_STORE_PASSWORD`) |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64` | *(Optional, after first manual AAB upload)* Base64-encoded Google Cloud service-account JSON granted **Release manager** in Play Console |

Once `MICDROP_ANDROID_UPLOAD_*` secrets are set:
- Every `main` push or `Build and audio contracts` workflow run builds, 16 KB-verifies, JAR-verifies, and uploads `app-release.aab` as the `android-play-aab` workflow artifact.
- **First upload:** Google Play Console requires the very first `.aab` of a new app to be uploaded manually in the Play Console web UI to enroll Play App Signing.
- **Subsequent uploads:** Trigger `Build and audio contracts` via `workflow_dispatch` with `play_track` set to `internal`, `alpha`, `beta`, or `production`.

### 2.2 Store Listing Copy & Assets

- **App Icon (`512 × 512` 32-bit PNG):** `apps/android/play-store/icon-512.png`
- **Feature Graphic (`1024 × 500` 24-bit PNG):** `apps/android/play-store/feature-graphic-1024x500.png`
- **Category:** `Music & Audio` (or `Tools`)
- **App Name (7 / 30 chars):**
  ```text
  MicDrop
  ```
- **Short Description (75 / 80 chars):**
  ```text
  Stream PC audio over Wi-Fi to your phone and use your phone mic on Windows.
  ```
- **Full Description (1,346 / 4,000 chars):**
  ```text
  MicDrop streams desktop audio from your computer to your Android phone over local Wi-Fi and lets you send your phone or headset microphone back to your PC—with no account, cloud login, or subscription.

  LISTEN, TALK, OR BOTH
  • PC to Phone (Listen): Hear Windows 11 desktop audio (plus experimental Linux and Apple Silicon Mac hosts) through your phone speaker, wired headphones, USB audio, or Bluetooth headphones.
  • Phone to PC (Talk): Route your phone or headset microphone into Discord, OBS, voice chat, games, or recording software using a standard desktop virtual audio cable.
  • Full Duplex (Both): Listen to desktop playback and talk back simultaneously over a single encrypted WebRTC session.

  DESIGNED FOR PRIVACY & CONTROL
  • Direct Local Pairing: Scan a one-time QR code or paste an invitation link from the open-source MicDrop desktop app, then approve the pairing on your computer.
  • Mutual TLS & Pinned Identity: Control traffic and WebRTC audio streams are encrypted end-to-end between your paired phone and desktop host.
  • Explicit Session Lifecycle: Audio playback and microphone capture run only when you tap Connect, show persistent system status indicators while active, and stop immediately when you tap Stop.
  • Open Source: First-party code is licensed under MPL-2.0 with no ads, analytics SDKs, or telemetry.

  REQUIREMENTS
  Requires the free, open-source MicDrop desktop host running on Windows 11 (or experimental Linux x64 / Apple Silicon macOS) on the same Wi-Fi network, or an optional user-configured self-hosted relay for remote connections.
  ```

### 2.3 Google Play App Content Declarations

1. **Privacy Policy:** `https://maskarauder.com/micdrop/privacy/`
2. **Ads:** *No, my app does not contain ads.*
3. **Target Audience:** `18 and over` (or `13–15, 16–17, 18 and over`; *not* targeted at children under 13).
4. **Advertising ID (`AD_ID`):** *No* (not declared in `AndroidManifest.xml`, no Play Services ads/analytics SDKs).
5. **Data Safety Questionnaire:**
   - *Does your app collect or share any of the required user data types?* → **No.**
   - Rationale: Audio frames are streamed ephemerally peer-to-peer over DTLS-SRTP directly to the user's own paired computer (or optional user-configured self-hosted TURN server) and are never collected by or transmitted to the developer. Camera frames for QR scanning are decoded on-device in memory and discarded immediately.
6. **Foreground Service (`FOREGROUND_SERVICE_MEDIA_PLAYBACK` & `FOREGROUND_SERVICE_MICROPHONE`) Declaration:**
   - **`mediaPlayback` justification:**
     ```text
     When the user taps Connect with "Play desktop audio" enabled, MicDrop starts PlaybackService with foregroundServiceType="mediaPlayback" and a persistent MediaSession notification (Pause / Stop) so live WebRTC desktop audio continues playing reliably when the user switches apps or locks the phone screen. Stopping the session immediately stops the foreground service.
     ```
   - **`microphone` justification:**
     ```text
     When the user taps Connect in the foreground with "Send microphone" enabled and grants RECORD_AUDIO, MicDrop starts MicrophoneService with foregroundServiceType="microphone" and a persistent notification (Mute / Stop) so the user's voice continues transmitting to their paired PC while viewing another app or locking the screen. Microphone capture never starts from the background and stops immediately on Stop.
     ```
   - **Video walkthrough requirement:** Record a short (`30–60 s`) screen/camera clip showing: (1) tapping `Connect` inside MicDrop, (2) locking the screen / switching apps while the persistent notification stays visible and audio/mic continues, and (3) tapping `Stop` in the notification/app dismissing the foreground service.
7. **App Access Instructions (for Play Reviewers):**
   - Select *All or some functionality is restricted* → provide instructions explaining that MicDrop pairs with the free open-source MicDrop desktop app (`https://github.com/maskarauder/MicDrop/releases`), and note that reviewers without a Windows PC can also exercise local audio playback directly on-device via `Diagnostics → Start local output test → Play click`.

---

## 3. Apple iPhone App Store Setup & Metadata

### 3.1 Build, Signing & Automated Screenshots

`ios.yml` (`iPhone app`) already archives, signs (`Apple Distribution`), verifies `AppIcon.png` (`1024 × 1024`) + `PrivacyInfo.xcprivacy`, and uploads `com.maskarauder.micdrop` directly to **App Store Connect / TestFlight** when dispatched with `upload_testflight = true`. The exact same signed TestFlight build can be attached directly to the **1.0 / 0.1.0 iOS App Store** version in App Store Connect without rebuilding.

`ios-screenshots.yml` (`iPhone App Store screenshots`) automatically boots iOS Simulators on `macos-26` (with a clean `9:41` status bar, full Wi-Fi/signal/battery, dark mode, and Debug-only deterministic scenes), captures 4 real UI screenshots (`01-connection-setup.png`, `02-connected-audio-output.png`, `03-microphone-controls.png`, `04-diagnostics-local-test.png`), converts them to strict alpha-free 24-bit RGB PNGs (`color_type=2`), validates dimensions and UI rendering via `tools/app_store_screenshots.py`, and uploads them as the **`ios-app-store-screenshots`** GitHub Actions artifact:
- `iphone-6.3/*.png` (`1206 × 2622`, iPhone with Dynamic Island — medium display, required by App Store Connect)
- `iphone-6.9/*.png` (`1320 × 2868`, iPhone with Dynamic Island — large display, optional / legacy 6.9" slot)

You can also trigger `iPhone App Store screenshots` manually from the GitHub Actions tab via `workflow_dispatch`.

### 3.2 App Store Connect Listing Copy

- **Name (7 / 30 chars):**
  ```text
  MicDrop
  ```
- **Subtitle (27 / 30 chars):**
  ```text
  PC Audio & Wi-Fi Microphone
  ```
- **Primary Category:** `Music` (or `Utilities`)
- **Secondary Category:** `Utilities` (or `Productivity`)
- **Promotional Text (158 / 170 chars):**
  ```text
  Listen to Windows 11 desktop audio over Wi-Fi through your iPhone and headphones, or send your iPhone microphone back for Discord, OBS, calls, and recordings.
  ```
- **Keywords (96 / 100 chars):**
  ```text
  pc,audio,speaker,microphone,wifi,windows,webrtc,headset,wireless,stream,obs,discord,loopback,lan
  ```
- **Support URL:** `https://maskarauder.com/micdrop/`
- **Marketing URL:** `https://maskarauder.com/micdrop/`
- **Privacy Policy URL:** `https://maskarauder.com/micdrop/privacy/`
- **Copyright:** `2026 Maskarauder`
- **Description:** Reuse the Full Description in §2.2 (substituting `iPhone` for `Android phone` in the opening sentence):
  ```text
  MicDrop streams desktop audio from your computer to your iPhone over local Wi-Fi and lets you send your iPhone or headset microphone back to your PC—with no account, cloud login, or subscription.

  LISTEN, TALK, OR BOTH
  • PC to Phone (Listen): Hear Windows 11 desktop audio (plus experimental Linux and Apple Silicon Mac hosts) through your iPhone speaker, wired/USB audio, AirPods, or Bluetooth headphones.
  • Phone to PC (Talk): Route your iPhone or headset microphone into Discord, OBS, voice chat, games, or recording software using a standard desktop virtual audio cable.
  • Full Duplex (Both): Listen to desktop playback and talk back simultaneously over a single encrypted WebRTC session.

  DESIGNED FOR PRIVACY & CONTROL
  • Direct Local Pairing: Scan a one-time QR code or paste an invitation link from the open-source MicDrop desktop app, then approve the pairing on your computer.
  • Mutual TLS & Pinned Identity: Control traffic and WebRTC audio streams are encrypted end-to-end between your paired iPhone and desktop host.
  • Explicit Session Lifecycle: Audio playback and microphone capture run only when you tap Connect, integrate with Lock Screen Now Playing controls while active, and stop immediately when you tap Stop.
  • Open Source: First-party code is licensed under MPL-2.0 with no ads, analytics SDKs, or telemetry.

  REQUIREMENTS
  Requires the free, open-source MicDrop desktop host running on Windows 11 (or experimental Linux x64 / Apple Silicon macOS) on the same Wi-Fi network, or an optional user-configured self-hosted relay for remote connections.
  ```

### 3.3 App Store Connect Privacy, Encryption & Age Rating

- **App Privacy (Nutrition Label):** *Data Not Collected* (matches bundled `apps/ios/MicDrop/PrivacyInfo.xcprivacy`: `NSPrivacyCollectedDataTypes = []`, `NSPrivacyTracking = false`).
- **Export Compliance:** Exempt (`ITSAppUsesNonExemptEncryption = false` is already declared in `apps/ios/MicDrop/Info.plist` for standard TLS / DTLS-SRTP OS/WebRTC transport encryption).
- **Content Rights:** *No, it does not contain, show, or access third-party content.*
- **Age Rating:** Select *None* / *No* for all violence, mature, gambling, medical, and unrestricted web access prompts (`4+`).

### 3.4 App Review Information (Notes for Apple Reviewer)

Paste the following into **App Review Information → Notes** (sign-in required = **unchecked**, since MicDrop uses no accounts):

```text
MicDrop is a local Wi-Fi companion audio utility that pairs directly with the free, open-source MicDrop desktop host app (available at https://github.com/maskarauder/MicDrop/releases for Windows 11, Apple Silicon macOS 14.2+, and Linux x64). No user account or login exists.

HOW TO TEST WITHOUT A PAIRED COMPUTER (ON-DEVICE):
1. Open MicDrop on iPhone and expand all five sections (Connection setup, Audio output, Microphone, Advanced, Diagnostics).
2. In Connection setup, tap "Scan pairing QR" to verify Camera permission handling, or "Find Windows on LAN" to verify Local Network (_micdrop._tcp Bonjour) discovery.
3. Expand "Diagnostics", tap "Start local output test", and tap "Play click" to verify real-time native audio engine initialization and output playback directly on the iPhone. Tap "Stop" to end the test.
4. In Diagnostics, tap "Open-source notices" and "Privacy policy" to verify bundled notices and policy access.

HOW TO TEST FULL END-TO-END STREAMING WITH A MAC OR WINDOWS PC ON THE SAME WI-FI:
1. Download MicDrop.app (macOS arm64, Apple-notarized) or MicDrop Setup (Windows 11, Authenticode-signed) from https://github.com/maskarauder/MicDrop/releases.
2. Open the desktop app -> Phones -> Pair a phone to display a one-time pairing QR code.
3. In MicDrop on iPhone, scan the QR code, tap Connect, and click Approve on the desktop app.
4. Background audio mode ("audio" in UIBackgroundModes) keeps live desktop audio playback and/or active voice microphone streaming running when the iPhone screen locks, with Lock Screen Now Playing Pause/Stop controls.

Please also see the attached demo video showing live desktop pairing, Lock Screen audio controls, and microphone return.
```
