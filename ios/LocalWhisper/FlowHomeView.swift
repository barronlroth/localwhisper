import AVFoundation
import SwiftUI
import UIKit

struct FlowHomeView: View {
    @Bindable var router: AppRouter
    private var store = SharedStore.shared

    enum TestEngine: String, CaseIterable, Identifiable {
        case webView = "WebView Hack"
        case native = "Native Mic"
        var id: String { rawValue }
    }

    @State private var micGranted = false
    @State private var keyboardInstalled = false
    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var isCheckingHealth = false

    @State private var playgroundText = ""
    @State private var testEngine: TestEngine = .webView
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var waveformLevels: [CGFloat] = Array(repeating: 0.08, count: 24)
    @State private var statusBanner: String?
    @State private var telemetryLine: String = ""

    @State private var nativeRecorder = NativeAudioRecorder()
    @State private var webViewRecorder = WebViewAudioRecorder()
    @State private var streamSession: ParakeetStreamSession?
    @FocusState private var isEditorFocused: Bool

    private var coral: Color { Color("AccentColor") }

    var body: some View {
        NavigationStack {
            List {
                serverStatusSection
                if !allSetupComplete {
                    setupChecklistSection
                }
                playgroundSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LocalWhisper")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await pingServer() }
                    } label: {
                        if isCheckingHealth {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Refresh Mac mini connection")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditorFocused = false }
                }
            }
            .background(
                // Hidden 1x1 host view so WebViewAudioRecorder can be benchmarked inside the app too
                WebViewHostRepresentable { hostView in
                    webViewRecorder.attach(to: hostView, prewarm: store.prewarmWebView)
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            )
            .task {
                configureRecorders()
                refreshLocalChecks()
                await pingServer()
                if router.shouldPromptMicPermission {
                    router.shouldPromptMicPermission = false
                    await requestMicrophone()
                }
            }
            .onChange(of: router.shouldPromptMicPermission) { _, shouldPrompt in
                if shouldPrompt {
                    router.shouldPromptMicPermission = false
                    Task { await requestMicrophone() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshLocalChecks()
                Task { await pingServer() }
            }
        }
    }

    private var allSetupComplete: Bool {
        micGranted && keyboardInstalled && (health?.ready == true)
    }

    // MARK: - Sections

    private var serverStatusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let health {
                    Text("\(Int(round(health.pingMs)))ms")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.14), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var setupChecklistSection: some View {
        Section("Setup") {
            setupRow(
                title: "Microphone Permission",
                subtitle: micGranted ? "Granted for voice dictation" : "Required once so the keyboard can record",
                done: micGranted,
                buttonTitle: "Allow"
            ) {
                Task { await requestMicrophone() }
            }

            setupRow(
                title: "Enable LocalWhisper Keyboard",
                subtitle: keyboardInstalled
                    ? "Installed — ensure Full Access is on"
                    : "Settings → Keyboards → Add LocalWhisper & Allow Full Access",
                done: keyboardInstalled,
                buttonTitle: "Settings"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

            setupRow(
                title: "Local Parakeet Server",
                subtitle: health?.ready == true
                    ? "Model warm on Tailscale"
                    : (healthError ?? "Make sure Tailscale is on and server is running"),
                done: health?.ready == true,
                buttonTitle: "Ping"
            ) {
                Task { await pingServer() }
            }
        }
    }

    private func setupRow(
        title: String,
        subtitle: String,
        done: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !done {
                Button(buttonTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var playgroundSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if playgroundText.isEmpty {
                    Text("Tap here and switch to LocalWhisper with the globe key, or use the mic test button below…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $playgroundText)
                    .focused($isEditorFocused)
                    .frame(minHeight: 112)
                    .scrollContentBackground(.hidden)
            }

            VStack(spacing: 14) {
                Picker("Mic Engine", selection: $testEngine) {
                    ForEach(TestEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isRecording || isTranscribing)

                if isRecording || isTranscribing {
                    WaveformView(
                        levels: waveformLevels,
                        tint: isTranscribing ? .secondary : coral,
                        barWidth: 3.5,
                        spacing: 3.5,
                        minHeight: 5,
                        maxHeight: 36,
                        isPulsing: isTranscribing
                    )
                }

                HStack(spacing: 12) {
                    Button {
                        if isRecording {
                            stopPlaygroundRecording()
                        } else {
                            startPlaygroundRecording()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            Text(isTranscribing ? "Transcribing…" : (isRecording ? "Stop & Transcribe" : "Test \(testEngine.rawValue)"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRecording ? .red : coral)
                    .disabled(isTranscribing)

                    if !playgroundText.isEmpty {
                        Button {
                            UIPasteboard.general.string = playgroundText
                            HapticFeedback.keyTap()
                            statusBanner = "Copied text"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Copy playground text")
                    }
                }

                if let statusBanner {
                    Text(statusBanner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !telemetryLine.isEmpty {
                    Text(telemetryLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Dictation Playground")
        } footer: {
            Text("“WebView Hack” runs the exact same invisible WKWebView audio pipeline that powers no-app-switch dictation inside the keyboard extension.")
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if health?.ready == true { return .green }
        if healthError != nil { return coral }
        return .orange
    }

    private var statusTitle: String {
        if let health, health.ready {
            return "Mac mini Connected"
        }
        if isCheckingHealth { return "Checking Mac mini…" }
        return "Mac mini Unreachable"
    }

    private var statusSubtitle: String {
        if let health {
            let shortModel = health.model.components(separatedBy: "/").last ?? health.model
            let host = URL(string: store.serverURL)?.host ?? store.serverURL
            return "\(shortModel) · \(host)"
        }
        return healthError ?? store.serverURL
    }

    private func refreshLocalChecks() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        let modes = UITextInputMode.activeInputModes
        let expected = AppGroup.keyboardBundleIdentifier
        keyboardInstalled = modes.contains { mode in
            (mode.value(forKey: "identifier") as? String)?.contains(expected) == true
        }
    }

    private func requestMicrophone() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        micGranted = granted
        if !granted, let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    private func pingServer() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        do {
            let res = try await ParakeetClient.shared.checkHealth(
                serverURL: store.serverURL,
                apiToken: store.apiToken
            )
            health = res
            healthError = nil
        } catch {
            health = nil
            healthError = error.localizedDescription
        }
    }

    private func configureRecorders() {
        webViewRecorder.onPCMChunk = { chunk, level in
            pushLevel(CGFloat(level))
            if let session = streamSession {
                Task { await session.appendPCMChunk(chunk) }
            }
        }
        webViewRecorder.onRecordingLive = { metrics in
            telemetryLine = metrics.summary
        }
        webViewRecorder.onError = { err in
            isRecording = false
            isTranscribing = false
            statusBanner = err.localizedDescription
            HapticFeedback.error()
        }

        nativeRecorder.onPCMChunk = { chunk, level in
            pushLevel(CGFloat(level))
            if let session = streamSession {
                Task { await session.appendPCMChunk(chunk) }
            }
        }
    }

    private func startPlaygroundRecording() {
        statusBanner = nil
        waveformLevels = Array(repeating: 0.08, count: 24)
        let context = playgroundText.isEmpty ? nil : String(playgroundText.suffix(80))

        let session = ParakeetStreamSession(
            serverURL: store.serverURL,
            apiToken: store.apiToken,
            mode: store.mode,
            dictionary: store.dictionary,
            context: context,
            smartSpacing: store.smartSpacing,
            enableWebSocket: store.useStreamingWebSocket
        )
        self.streamSession = session
        Task { await session.open() }

        HapticFeedback.startListening()

        switch testEngine {
        case .webView:
            isRecording = true
            webViewRecorder.startRecording()
        case .native:
            do {
                try nativeRecorder.startRecording()
                isRecording = true
                telemetryLine = "native AVAudioEngine @16000Hz"
            } catch {
                statusBanner = error.localizedDescription
                HapticFeedback.error()
            }
        }
    }

    private func stopPlaygroundRecording() {
        isRecording = false
        isTranscribing = true
        HapticFeedback.stopListening()

        let duration: Double
        switch testEngine {
        case .webView:
            (_, duration) = webViewRecorder.stopRecording()
        case .native:
            (_, duration) = nativeRecorder.stopRecording()
        }

        let activeSession = streamSession
        streamSession = nil

        Task {
            do {
                guard let activeSession else { return }
                let response = try await activeSession.finish()
                if !response.text.isEmpty {
                    playgroundText += response.text
                    let record = DictationRecord(
                        text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        rawText: response.rawText,
                        durationSeconds: max(duration, response.durationSeconds),
                        inferenceMs: response.inferenceMs,
                        mode: store.mode,
                        source: testEngine == .webView ? "App (WebView)" : "App (Native)"
                    )
                    store.appendHistory(record)
                    statusBanner = "Transcribed \(String(format: "%.1fs", response.durationSeconds)) audio in \(Int(round(response.inferenceMs)))ms"
                    HapticFeedback.inserted()
                } else {
                    statusBanner = "No speech detected"
                }
            } catch {
                statusBanner = error.localizedDescription
                HapticFeedback.error()
            }
            isTranscribing = false
        }
    }

    private func pushLevel(_ level: CGFloat) {
        var next = waveformLevels
        let mid = next.count / 2
        for i in 0..<(mid - 1) {
            next[i] = next[i + 1] * 0.92
        }
        for i in stride(from: next.count - 1, through: mid + 1, by: -1) {
            next[i] = next[i - 1] * 0.92
        }
        next[mid - 1] = max(0.08, level)
        next[mid] = max(0.08, level)
        waveformLevels = next
    }
}

private struct WebViewHostRepresentable: UIViewRepresentable {
    let onAttach: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            onAttach(view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
