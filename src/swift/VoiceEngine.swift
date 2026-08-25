import Foundation
import Combine
import Security
import AVFoundation
import IOKit.hid

/// VoiceEngine does ALL the hard work of running the embedded `voice-engine`
/// helper: finding it in the app, asking for permissions, launching it, reading
/// its status, and stopping it cleanly. You never have to edit this file.
///
/// In your GUI, use the shared instance:
///
///     @StateObject private var voice = VoiceEngine.shared
///
/// and read these published values to draw your screen:
///   • voice.state        - .loading / .idle / .recording / .transcribing / .needsSetup
///   • voice.statusText   - a friendly sentence you can show directly
///   • voice.lastText     - the most recent transcript
///   • voice.setupHint    - if something needs fixing, a plain-English how-to
///
/// The app calls `VoiceEngine.shared.go()` once at launch (see DictationApp),
/// and `VoiceEngine.shared.retry()` from a "Try Again" button.
final class VoiceEngine: ObservableObject {

    static let shared = VoiceEngine()

    enum State: String {
        case loading, idle, recording, transcribing, stopped, needsSetup
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var lastText: String = ""
    @Published private(set) var cleanupEnabled = false
    @Published private(set) var setupHint: String? = nil

    // Everything below is touched only on the main thread, except the stdout
    // reader, which parses on its own queue and hops to main to publish.
    private var process: Process?
    private var outPipe: Pipe?
    private var stdoutBuffer = Data()
    private var generation = 0       // bumps each launch/stop so a dying process can't stomp a new one
    private var isStarting = false   // guards against a double launch while permissions resolve
    private var sawReady = false     // did the current helper reach "ready"?

    private init() {}

    var statusText: String {
        switch state {
        case .needsSetup:    return setupHint ?? "A setup step is needed."
        case .loading:       return "Starting up… the first launch can take about 30 seconds."
        case .idle:          return cleanupEnabled
                                ? "Ready! Hold the Fn key and talk."
                                : "Ready (no AI cleanup). Hold the Fn key and talk."
        case .recording:     return "Listening…"
        case .transcribing:  return "Writing down what you said…"
        case .stopped:       return "Stopped."
        }
    }

    var hasStoredKey: Bool { KeychainStore.loadAPIKey() != nil }

    // MARK: - one call that does everything

    /// Find resources, ask for permissions, and start the helper. Safe to call
    /// again (e.g. from a "Try Again" button); it won't start a second copy.
    func go() {
        guard process == nil, !isStarting else { return }

        let exe: URL
        switch locateExecutable() {
        case .notFound:
            needSetup("I can't find the voice-engine helper. In Xcode, drag the "
                + "'voice-engine' folder into the app (choose “Create folder references”).")
            return
        case .notExecutable(let url):
            // Xcode folder references usually keep the +x bit, but repair it if not.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                needSetup("The voice-engine helper isn't runnable. Re-add the 'voice-engine' "
                    + "folder to the app as a folder reference and try again.")
                return
            }
            exe = url
        case .ok(let url):
            exe = url
        }

        guard let model = locateModel() else {
            needSetup("I can't find the speech model. Drag 'ggml-small.en-q5_1.bin' "
                + "(about 181 MB) into the app — at the top level or inside a 'models' folder.")
            return
        }

        isStarting = true
        requestMicrophone { [weak self] micOK in
            guard let self else { return }
            guard micOK else {
                self.isStarting = false
                self.needSetup("Microphone access is off. Turn it on in System Settings → "
                    + "Privacy & Security → Microphone, then press Try Again.")
                return
            }
            guard self.ensureInputMonitoring() else {
                self.isStarting = false
                self.needSetup("Please switch ON this app in System Settings → Privacy & "
                    + "Security → Input Monitoring. Then quit the app (Cmd-Q) and open it again, "
                    + "or press Try Again.")
                return
            }
            self.launch(exe: exe, model: model)
        }
    }

    /// Re-run setup/launch (for a "Try Again" button after fixing a permission).
    func retry() { go() }

    /// Save a new API key and relaunch so cleanup turns on.
    func restart() {
        state = .loading
        stop()
        go()
    }

    /// Stop the helper cleanly (it releases the microphone). Guarantees the
    /// child is gone even if it ignores SIGTERM.
    func stop() {
        generation += 1                  // invalidate the current process's handler
        isStarting = false
        outPipe?.fileHandleForReading.readabilityHandler = nil
        let dying = process
        process = nil
        outPipe = nil
        stdoutBuffer = Data()
        guard let dying else { return }
        dying.terminate()                // SIGTERM -> engine releases the mic and exits
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(2.0)
            while dying.isRunning && Date() < deadline { usleep(50_000) }
            if dying.isRunning { kill(dying.processIdentifier, SIGKILL) }
        }
    }

    deinit { process?.terminate() }

    // MARK: - finding the bundled files

    private enum ExeResult { case ok(URL), notExecutable(URL), notFound }

    private func locateExecutable() -> ExeResult {
        let fm = FileManager.default
        let found = candidates(of: "voice-engine", in: ["voice-engine.bundle"])
            .first { fm.fileExists(atPath: $0.path) }
        guard let url = found else { return .notFound }
        return fm.isExecutableFile(atPath: url.path) ? .ok(url) : .notExecutable(url)
    }

    private func locateModel() -> URL? {
        let name = "ggml-small.en-q5_1.bin"
        return candidates(of: name, in: ["models", "voice-engine.bundle"])
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Plausible locations for a bundled file: at the Resources root and inside
    /// any of the given subfolders. Keeps the kid from needing one exact spot.
    private func candidates(of file: String, in subdirs: [String]) -> [URL] {
        guard let res = Bundle.main.resourceURL else { return [] }
        var urls = [res.appendingPathComponent(file)]
        for sub in subdirs {
            urls.append(res.appendingPathComponent(sub).appendingPathComponent(file))
        }
        return urls
    }

    // MARK: - permissions

    private func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    private func ensureInputMonitoring() -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            return true
        }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)  // adds app to the list / prompts
        return false
    }

    // MARK: - launching the helper

    private func launch(exe: URL, model: URL) {
        generation += 1
        let myGen = generation
        sawReady = false

        let p = Process()
        p.executableURL = exe
        p.arguments = ["--headless", "--model", model.path]

        var env = ProcessInfo.processInfo.environment
        if let key = KeychainStore.loadAPIKey(), !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
        }
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice   // the helper writes its own log file
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { self?.ingest(chunk) }
        }
        p.terminationHandler = { [weak self] task in
            let status = task.terminationStatus
            DispatchQueue.main.async {
                guard let self, myGen == self.generation else { return }   // ignore a stale (replaced) process
                self.outPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outPipe = nil
                if self.state == .needsSetup {
                    // A specific error (e.g. mic/model) was already shown — keep it.
                } else if !self.sawReady && status != 0 {
                    self.needSetup("The helper stopped right after starting. If you just "
                        + "downloaded the app, right-click it and choose Open once. Otherwise, "
                        + "check Input Monitoring is on and that App Sandbox is removed, then "
                        + "press Try Again.")
                } else {
                    self.state = .stopped
                }
            }
        }

        stdoutBuffer = Data()
        do {
            try p.run()
            process = p
            outPipe = pipe
            isStarting = false
            setupHint = nil
            state = .loading
        } catch {
            isStarting = false
            pipe.fileHandleForReading.readabilityHandler = nil
            needSetup("The helper couldn't start. In Xcode, open the app target → Signing & "
                + "Capabilities and remove “App Sandbox” (click the x), then press Play again."
                + "\n\n(\(error.localizedDescription))")
        }
    }

    private func needSetup(_ message: String) {
        DispatchQueue.main.async {
            self.setupHint = message
            self.state = .needsSetup
        }
    }

    // MARK: - reading the helper's status (one JSON object per line on stdout)

    private func ingest(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let event = obj["event"] as? String
            else { continue }
            DispatchQueue.main.async { self.handle(event, obj) }
        }
    }

    private func handle(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "ready":
            sawReady = true
            cleanupEnabled = obj["cleanup"] as? Bool ?? false
            state = .idle
        case "cleanup":
            cleanupEnabled = obj["enabled"] as? Bool ?? false
        case "state":
            if let v = obj["value"] as? String, let s = State(rawValue: v) { state = s }
        case "result":
            lastText = obj["text"] as? String ?? ""
        case "error":
            let code = obj["code"] as? String ?? ""
            let msg = obj["message"] as? String ?? "Something went wrong."
            switch code {
            case "mic_unavailable":
                needSetup("I couldn't use the microphone. Turn it on in System Settings → "
                    + "Privacy & Security → Microphone, then press Try Again.")
            case "model_missing":
                needSetup("I couldn't load the speech model. Re-add 'ggml-small.en-q5_1.bin' "
                    + "(about 181 MB) to the app and press Try Again.")
            default:
                NSLog("voice-engine error [\(code)]: \(msg)")   // transient; keep running
            }
        default:
            break
        }
    }
}


// MARK: - Keychain storage for the user's Anthropic key

/// Stores the user's own Anthropic API key in the macOS Keychain. The key is
/// never written to disk in plaintext and never bundled into the app.
enum KeychainStore {
    private static let service = "VoiceApp"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let data = Data(trimmed.utf8)
        // Update in place if it exists, so a failure never destroys the old key.
        let update = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func loadAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    static func deleteAPIKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
