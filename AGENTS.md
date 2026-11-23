# AGENTS.md

Guide for AI coding agents and contributors working on **LocalWhisper** — a private, self-hosted, Wispr Flow–style iOS dictation keyboard backed by local NVIDIA Parakeet MLX on Apple Silicon over Tailscale HTTPS.

---

## Architecture Overview

LocalWhisper has two components:

1. **Mac Transcription Server (`server/`)**
   - FastAPI + `parakeet-mlx` (`mlx-community/parakeet-tdt-0.6b-v3` by default), managed with `uv` on Python 3.14.
   - Binds strictly to `127.0.0.1:43120` and is exposed **tailnet-only** over HTTPS via `tailscale serve --bg --set-path /parakeet http://127.0.0.1:43120`.
   - Exposes `GET /health`, `POST /v1/transcribe` (WAV/PCM fast path without spawning `ffmpeg`, plus `ffmpeg` fallback for other formats), `WS /v1/stream` (streams 16 kHz Int16 PCM while speaking for minimal post-stop latency), and `GET/PUT/POST/DELETE /v1/dictionary` (canonical JSON personal dictionary hosted at `~/Library/Application Support/LocalWhisper/dictionary.json` with mtime hot-reload, shared across iPhone/iPad clients).
   - Runs a periodic idle keep-warm pass (`PARAKEET_KEEPWARM_SECONDS=180`) so macOS does not page Parakeet’s weights out to swap overnight.
   - Deterministic post-processing (`server/postprocess.py`): filler-word removal, stutter collapse, personal dictionary replacements, spoken line breaks/notes bullets, and cursor-context capitalization & spacing.

2. **iOS Companion App + Custom Keyboard Extension (`ios/`)**
   - Generated via **XcodeGen** from `ios/project.yml` → `ios/LocalWhisper.xcodeproj` (the `.xcodeproj` is gitignored and regenerated on build).
   - **`ios/Shared/`** (compiled into *both* targets): App Group settings/history/dictionary store (`SharedConfig.swift`), 16 kHz WAV encoder (`AudioWAVEncoder.swift`), WebSocket + HTTP client (`ParakeetClient.swift`), invisible `WKWebView` mic capture engine (`WebViewAudioRecorder.swift`), waveform UI (`WaveformView.swift`), haptics (`HapticFeedback.swift`), and `PrivacyInfo.xcprivacy`.
   - **`ios/LocalWhisperKeyboard/`**: Wispr Flow–style custom keyboard extension — Numbers & Symbols (`123`) primary layout, `#+=` secondary symbols, `ABC` QWERTY letters, top-left Settings link (`localwhisper://settings`), Undo button, Style picker (`Clean` / `Casual` / `very casual` / `Notes` / `Raw`), and top-right Record toggle with live top-bar waveform.
   - **`ios/LocalWhisper/`**: Companion SwiftUI app (Setup Checklist, Dictation Playground with both WebView Hack and Native `AVAudioEngine` testers, searchable History, Personal Dictionary, Settings, and `localwhisper://dictate` fallback recorder).

---

## Privacy & Secrets Hygiene (Public Repository)

This repository is **public**. Never commit personal Apple Team IDs, bundle IDs, App Group IDs, device UDIDs, private Tailscale hostnames (`*.ts.net`), local user paths (`/Users/...`), certificates, or API tokens.

- All personal iOS build overrides live in gitignored `ios/Config/Local.xcconfig` (template: `ios/Config/Local.xcconfig.example`).
- `ios/Config/Base.xcconfig` holds safe placeholder defaults and `#include? "Local.xcconfig"`.
- `Info.plist` and `.entitlements` reference build variables (`$(APP_BUNDLE_ID)`, `$(KEYBOARD_BUNDLE_ID)`, `$(APP_GROUP_ID)`, `$(DEFAULT_SERVER_URL)`), which `SharedConfig.swift` reads dynamically from `Bundle.main.infoDictionary`.
- `server/install_service.sh` generates `~/Library/LaunchAgents/com.localwhisper.server.plist` dynamically from `$HOME` and `$SCRIPT_DIR` (never commit a `.plist` with hardcoded user paths).

---

## Development, Build & Push Workflows

### 1. Mac Server (`server/`)

```bash
# Run unit tests (audio decoding + post-processing)
cd server && uv run pytest -v

# Install/restart persistent LaunchAgent + Tailscale Serve route
./server/install_service.sh

# Check logs
tail -f ~/Library/Logs/LocalWhisper/stderr.log
```

### 2. iOS Local Verification (Simulator)

```bash
cd ios
xcodegen generate
xcodebuild \
  -project LocalWhisper.xcodeproj \
  -scheme LocalWhisper \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 3. Deploy Directly to a Paired iPhone (USB / Local Wi-Fi)

Requires `ios/Config/Local.xcconfig` with your `DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX`, and `DEFAULT_SERVER_URL`:

```bash
./ios/deploy_iphone.sh [OPTIONAL_DEVICE_UDID]
```

Auto-detects the first paired physical iPhone from `xcrun devicectl list devices`, regenerates `LocalWhisper.xcodeproj`, builds with `-allowProvisioningUpdates`, installs via `xcrun devicectl device install app`, and removes `ios/build/`.

### 4. Push a Build to TestFlight (Headless CI-Style Release)

```bash
./ios/upload_testflight.sh [OPTIONAL_BUILD_NUMBER]
```

How the TestFlight pipeline works:
1. Reads `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID`, and `KEYBOARD_BUNDLE_ID` from `ios/Config/Base.xcconfig` + `ios/Config/Local.xcconfig`.
2. If `~/.appstoreconnect/signing/distribution.keychain-db` and `~/.appstoreconnect/signing/.kc_pass` exist, unlocks that dedicated signing keychain and puts it first in the user keychain search list (restored on exit via `trap`) so `codesign` never blocks on a macOS login Keychain GUI dialog.
3. Runs `xcodegen generate`, then `xcodebuild archive` (`Release`, `CODE_SIGN_STYLE=Manual`, `Apple Distribution`, with `APP_PROVISIONING_PROFILE` and `KB_PROVISIONING_PROFILE` — defaults: `LocalWhisper AppStore` and `LocalWhisper Keyboard AppStore`).
4. Exports the signed App Store `.ipa` via `xcodebuild -exportArchive`.
5. Looks up the App Store Connect App ID via `asc apps list --bundle-id "$APP_BUNDLE_ID"` (or `ASC_APP_ID` env var) and uploads the `.ipa` with `asc builds upload --app <ID> --ipa <IPA_PATH>`.
6. Cleans up `ios/build/` after upload.

**Prerequisites for TestFlight upload:**
- `asc` CLI authenticated (`~/.asc/config.json` with App Store Connect API key).
- An **Apple Distribution** certificate imported into `~/.appstoreconnect/signing/distribution.keychain-db` with `security set-key-partition-list -S apple-tool:,apple:,codesign:`.
- `IOS_APP_STORE` provisioning profiles installed in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` for both the app and keyboard extension (with App Groups enabled).
- An App Store Connect app record matching `APP_BUNDLE_ID` (must be created once in App Store Connect web UI; an Internal TestFlight group with `--access-all-builds` delivers builds automatically without Beta App Review).

### 5. Git Commit & Push Checklist

Before committing and pushing to `origin main`:
1. Run server tests (`cd server && uv run pytest -v`) if `server/` changed.
2. Verify iOS compilation (`xcodegen generate` + `xcodebuild build`) if `ios/` changed.
3. Run a quick leak check on staged files to confirm no personal Team IDs, private `.ts.net` hostnames, device UDIDs, or `/Users/<name>` paths were staged:
   ```bash
   git diff --cached
   ```
4. Ensure `ios/Config/Local.xcconfig`, `ios/LocalWhisper.xcodeproj/`, `ios/build/`, and `server/.venv/` remain untracked/ignored.
5. Commit with a clear message and push to `origin main`.

---

## Critical iOS Platform Gotchas

- **Invisible `WKWebView` mic bridge (`WebViewAudioRecorder.swift`)**:
  - Must remain `1×1 pt`, `alpha = 0.01`, `isUserInteractionEnabled = false`, and mounted in the keyboard’s view hierarchy. Setting `isHidden = true`, `alpha = 0`, or detaching it causes WebKit to throttle/kill `getUserMedia`.
  - Keep `websiteDataStore = .nonPersistent()` to stay safely within the keyboard extension’s ~50–70 MB Jetsam memory cap.
  - Keep the RFC 2606 origin (`https://dictation.local.invalid/`) and only grant `.microphone` for that exact host in `WKUIDelegate`.
  - Never remove the 1s heartbeat / ~3.2s dead-man’s switch — it guarantees media tracks stop if iOS freezes or terminates the keyboard extension.
- **Extension API restrictions (`APPLICATION_EXTENSION_API_ONLY = YES`)**:
  - Everything in `ios/Shared/` and `ios/LocalWhisperKeyboard/` compiles as an app extension. Never reference `UIApplication.shared` there.
  - To open the containing app from the keyboard on iOS 18+, prefer SwiftUI `Link(destination:)` (and `extensionContext?.open(url)` + `openURL:options:completionHandler:` fallback); never use legacy `perform("openURL:")`.
- **XcodeGen entitlements gotcha**:
  - In `ios/project.yml`, always keep `properties:` populated under `entitlements:` (`com.apple.security.application-groups: [$(APP_GROUP_ID)]`). Omitting `properties:` causes `xcodegen generate` to overwrite the `.entitlements` files with an empty `<dict/>`, breaking App Group sync silently.
- **App Store / TestFlight metadata**:
  - Keep `ios/Shared/PrivacyInfo.xcprivacy` (declaring `NSPrivacyAccessedAPICategoryUserDefaults` reasons `CA92.1` and `1C8F.1`) and `ITSAppUsesNonExemptEncryption = false` in `ios/LocalWhisper/Info.plist`.
