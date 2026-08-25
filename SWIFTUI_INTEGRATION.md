# Embedding `voice-engine` in a SwiftUI app

This is the integration spec for the Python dictation engine built by
`voice.spec`. The build output is a self-contained folder:

```
dist/voice-engine/
  voice-engine          <- the executable your app launches
  _internal/            <- bundled Python, whisper.cpp, PortAudio, etc.
```

The engine is a background helper. Your SwiftUI app owns the window, the app
bundle, the permissions, and the API key. The engine does the audio capture,
transcription, and (optional) cleanup, and reports state back to you.

---

## 1. Where the pieces go in the app bundle

```
YourApp.app/Contents/
  MacOS/YourApp                         <- your SwiftUI binary
  Resources/
    voice-engine/                       <- the whole dist/voice-engine folder
      voice-engine
      _internal/...
    models/
      ggml-small.en-q5_1.bin            <- ship the model here (not in git)
  Info.plist
```

In Xcode: add the `voice-engine` folder and the `models` folder as **folder
references** (blue folders) via "Add Files to…", or add a "Copy Files" build
phase targeting Resources. Folder references preserve the internal layout, which
the helper needs.

> Do **not** turn on **App Sandbox** for this approach. A sandboxed app cannot
> `Process`-launch an embedded executable. This app is meant for direct
> distribution (a GitHub release), not the Mac App Store, so leave the sandbox
> off. (Hardened Runtime is fine and is needed later for notarization.)

---

## 2. Info.plist keys (on YOUR app)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Voice App records your voice to transcribe it to text.</string>
```

There is no Info.plist usage string for **Input Monitoring**. It is a separate
privacy permission (the engine reads the Fn key globally). You request it at
runtime (section 5) and the user grants it in System Settings.

---

## 3. Permissions to request from Swift, before starting the engine

```swift
import AVFoundation
import IOKit.hid

// Microphone
AVCaptureDevice.requestAccess(for: .audio) { granted in /* ... */ }

// Input Monitoring (needed for the global Fn-key listener)
let inputOK = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
// if false, send the user to:
// System Settings > Privacy & Security > Input Monitoring, and enable YourApp
```

The embedded helper inherits your app's granted permissions because it is a
child process of your signed app bundle. Grant them on the app, not the helper.

---

## 4. Launching the engine from your main view

```swift
import Foundation

final class VoiceEngine: ObservableObject {
    @Published var state: String = "idle"      // recording / transcribing / idle
    @Published var lastText: String = ""
    private var process: Process?

    func start(apiKey: String?) {
        let res = Bundle.main.resourceURL!
        let exe = res.appendingPathComponent("voice-engine/voice-engine")
        let model = res.appendingPathComponent("models/ggml-small.en-q5_1.bin")

        let p = Process()
        p.executableURL = exe
        p.arguments = [
            "--headless",                 // your app draws the UI, not the pill
            "--model", model.path,
            // omit --no-clipboard if you want the engine to copy for you
        ]

        // Bring-your-own-key: inject it as an env var. Never bundle it.
        var env = ProcessInfo.processInfo.environment
        if let apiKey { env["ANTHROPIC_API_KEY"] = apiKey }
        p.environment = env

        // Read the JSON status protocol off stdout
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let event = obj["event"] as? String else { continue }
                DispatchQueue.main.async { self?.handle(event: event, obj: obj) }
            }
        }

        try? p.run()
        self.process = p
    }

    private func handle(event: String, obj: [String: Any]) {
        switch event {
        case "ready":   state = "idle"
        case "state":   state = obj["value"] as? String ?? state
        case "result":  lastText = obj["text"] as? String ?? ""
        case "error":   print("engine error:", obj["message"] ?? "")
        default: break
        }
    }

    func stop() {
        process?.terminate()   // SIGTERM -> engine releases the mic and exits cleanly
        process = nil
    }
}
```

Call `start(apiKey:)` from your main view's `.onAppear` (or a Start button), and
`stop()` from `.onDisappear` / app termination.

---

## 5. The status protocol (engine stdout, one JSON object per line)

| event | fields | meaning |
|-------|--------|---------|
| `ready` | `keycode`, `cleanup` | engine loaded, listening |
| `cleanup` | `enabled`, `reason?` | whether AI cleanup is on (false = no key) |
| `state` | `value` = `recording` \| `transcribing` \| `idle` \| `stopped` | drive your pill/UI from this |
| `result` | `text`, `raw?`, `cleaned?`, `copied?`, `empty?` | final transcript |
| `error` | `code`, `message` | `model_missing`, `mic_unavailable`, … |

Diagnostic logs do **not** go to stdout; they go to
`~/Library/Logs/voice-app/voice-engine.log` (override with `--log`). That keeps
the stdout protocol clean.

---

## 6. Engine command-line options

| flag | default | purpose |
|------|---------|---------|
| `--headless` | off | don't draw the engine's own pill (let Swift own the UI) |
| `--model PATH` | search | path to the whisper `.bin` (pass your bundled model) |
| `--config PATH` | – | env file holding `ANTHROPIC_API_KEY` (alternative to env var) |
| `--no-clipboard` | off | don't write the clipboard (handle the `result` event yourself) |
| `--no-cleanup` | off | skip Claude cleanup, emit raw transcription |
| `--keycode N` | 63 | push-to-talk key code (63 = Fn) |
| `--threads N` | 6 | whisper threads |
| `--log PATH` | `~/Library/Logs/...` | log file |

---

## 7. Key handling

Resolution order inside the engine: `ANTHROPIC_API_KEY` env var, then
`--config` file, then `~/Library/Application Support/voice-app/.env`, then
`~/.config/voice-app/.env`. If none, the engine runs in raw-transcription mode
(no cleanup) and emits `{"event":"cleanup","enabled":false}`.

Recommended: have your app collect the user's key once, store it in the
**Keychain**, and inject it via the environment at launch. The key never touches
the binary or the repo.

---

## 8. Distribution (matches the chosen unsigned path)

For a v1 GitHub release without an Apple Developer ID:

1. Build/zip `YourApp.app`.
2. Tell users in the README: first launch, **right-click the app → Open** (or
   run `xattr -dr com.apple.quarantine YourApp.app`), then grant Microphone and
   Input Monitoring when prompted.

When you later enroll in the Apple Developer Program: sign the helper and its
`_internal` dylibs first (inside-out), then the app, with Hardened Runtime and
the `com.apple.security.device.audio-input` entitlement, then notarize and
staple. The engine binary itself is already ad-hoc signed by PyInstaller.

---
