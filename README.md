# Voice Dictation

A simple push-to-talk dictation app for macOS. **Hold the Fn key, say something,
let go,** and your words appear on screen and are copied to the clipboard, ready
to paste anywhere. Speech is turned into text right on your Mac, and (optionally)
tidied up by Claude.

> **Works on:** Apple Silicon Macs (M1 or newer).

---

## Install

To install it, first download the installer here: [download](https://github.com/archer-cmd/voice-app/releases/download/1.0.0/Voice.App.pkg). Then open
the file and follow the instructions.

## Using it

1. Open the app. The colored dot shows what it's doing:
   - **green** = ready
   - **red** = listening (while you hold Fn)
   - **blue** = writing down what you said
2. **Hold the Fn key**, talk, then **let go**.
3. Your text shows up and is on the clipboard. Press **Cmd-V** to paste it.

The very first launch takes about **30 seconds** while it gets ready. Every
launch after that is instant.

## First-run permissions

macOS will ask for two things the first time. Both are needed:

- **Microphone** — so it can hear you. Click Allow. (If a second box mentions
  "voice-engine," allow that too.)
- **Input Monitoring** — so it can notice the Fn key. Turn the app **ON** in
  **System Settings → Privacy & Security → Input Monitoring**, then quit and
  reopen the app (or press **Try Again** in the window).

If anything isn't set up yet, the app says so in plain language and gives you a
**Try Again** button. It won't just crash.

## AI cleanup (optional)

Out of the box, the app writes down exactly what you said. If you want it to also
tidy things up (remove "um"s, fix punctuation), click **Add API Key** and paste
your own [Anthropic API key](https://console.anthropic.com/settings/keys).

- Your key is stored in your Mac's **Keychain** and never leaves your computer.
- Skip this and the app still works fully, just without the cleanup step.

## Privacy

- **Transcription happens entirely on your Mac.** Your audio never leaves the
  device.
- **Only if you add an API key**, the transcribed _text_ (not the audio) is sent
  to Anthropic to be cleaned up. No key, no network, fully local.

---

## Building it yourself

This repo has everything to build the app from scratch.

**The app (SwiftUI):** the Swift files and a step-by-step Xcode guide are in
[`swift/`](src/swift/). You drop the four `.swift` files plus `voice-engine` into a new SwiftUI macOS app and
run it. You only ever edit `ContentView.swift` to change how the app looks.

**The engine bundle** (`voice-engine`, which the app embeds) is in `src/voice-engine`. It is pre-built and ready to use.

Then package it for the app (one item Xcode can drop in):

Full details on the engine's options and the Swift integration are in
[SWIFTUI_INTEGRATION.md](SWIFTUI_INTEGRATION.md).

## How it works

The app is a small SwiftUI shell that owns the window, permissions, and your API
key. Inside it runs a self-contained helper (`voice-engine.bundle`) that does the
listening with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and the
optional cleanup with Claude. The two talk over a tiny text protocol, so the app
always knows whether it's idle, recording, or transcribing.

## License

MIT. See [LICENSE](LICENSE).
