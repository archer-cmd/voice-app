import SwiftUI

/// This is the screen. THIS is the file to play with! Change colors, text,
/// layout, fonts — whatever you like. It reads everything it needs from
/// `VoiceEngine.shared`, so you can redesign it freely without breaking the
/// machinery underneath.
struct ContentView: View {
    @StateObject private var voice = VoiceEngine.shared
    @State private var showKeyPrompt = false

    var body: some View {
        VStack(spacing: 24) {

            Text("Voice Dictation")
                .font(.largeTitle.bold())

            // The big colored dot that shows what's happening.
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 130, height: 130)
                Image(systemName: dotIcon)
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 0.2), value: voice.state)

            // A friendly sentence about what's going on (or how to fix setup).
            Text(voice.statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(voice.state == .needsSetup ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            // Shown only when a setup step is needed.
            if voice.state == .needsSetup {
                Button("Try Again") { voice.retry() }
                    .buttonStyle(.borderedProminent)
            }

            // The most recent thing you said.
            if !voice.lastText.isEmpty {
                ScrollView {
                    Text(voice.lastText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 140)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Spacer(minLength: 0)

            Button(voice.cleanupEnabled ? "Change API Key" : "Add API Key (for AI cleanup)") {
                showKeyPrompt = true
            }
            .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(width: 460, height: 560)
        .sheet(isPresented: $showKeyPrompt) {
            APIKeyPromptView(
                onSaved: { voice.restart() },   // relaunch so cleanup turns on
                onSkip:  { }
            )
        }
        // If we were waiting on a permission and the user comes back to the app
        // (e.g. after flipping Input Monitoring on), try again automatically.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            if voice.state == .needsSetup { voice.retry() }
        }
    }

    // Colors and icons for each state. Tweak these freely.
    private var dotColor: Color {
        switch voice.state {
        case .recording:     return .red
        case .transcribing:  return .blue
        case .idle:          return .green
        case .needsSetup:    return .orange
        default:             return .gray
        }
    }

    private var dotIcon: String {
        switch voice.state {
        case .recording:     return "mic.fill"
        case .transcribing:  return "waveform"
        case .idle:          return "checkmark"
        case .needsSetup:    return "wrench.and.screwdriver.fill"
        default:             return "hourglass"
        }
    }
}

#Preview {
    ContentView()
}
