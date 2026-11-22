import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class KeyboardViewModel {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case transcribing
        case inserted(preview: String, latencyMs: Int)
        case error(message: String, recovery: RecoveryAction)
    }

    enum RecoveryAction: Equatable {
        case none
        case retry
        case openMicSetup
        case openAppSettings
        case openFallbackDictation
    }

    enum ServerStatus: Equatable {
        case unknown
        case connected(pingMs: Int)
        case unreachable
    }

    var phase: Phase = .idle
    var hasFullAccess: Bool = false
    var serverStatus: ServerStatus = .unknown
    var waveformLevels: [CGFloat] = Array(repeating: 0.08, count: 24)
    var elapsedSeconds: Int = 0
    var canUndo: Bool = false
    var lastLatencyMs: Int?
    var mode: TranscriptionMode = SharedStore.shared.mode
    var showNeedsInputSwitchKey: Bool = true
    var isHoldingToTalk: Bool = false

    private let recorder = WebViewAudioRecorder()
    private var streamSession: ParakeetStreamSession?
    private var elapsedTimer: Timer?
    private var insertedResetTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var lastHealthCheckAt: Date?
    private var recordingStartedAt: Date?
    private var lastInsertedCharCount: Int = 0
    private var rawLevelHistory: [CGFloat] = Array(repeating: 0.06, count: 24)
    private var activeRecordingToken = UUID()

    // Callbacks provided by KeyboardViewController
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: ((Int) -> Void)?
    var onContextBeforeCursor: (() -> String?)?
    var onOpenURL: ((URL) -> Void)?
    var onAdvanceKeyboard: (() -> Void)?

    init() {
        configureRecorderCallbacks()
    }

    func attachRecorder(to hostView: UIView) {
        SharedStore.shared.reload()
        mode = SharedStore.shared.mode
        recorder.attach(to: hostView, prewarm: hasFullAccess && SharedStore.shared.prewarmWebView)
    }

    func handleAppear(hasFullAccess: Bool, needsInputModeSwitchKey: Bool) {
        self.hasFullAccess = hasFullAccess
        self.showNeedsInputSwitchKey = needsInputModeSwitchKey
        SharedStore.shared.reload()
        self.mode = SharedStore.shared.mode

        if hasFullAccess && SharedStore.shared.prewarmWebView {
            recorder.prewarm()
        }

        // Check if user returned from companion-app fallback dictation
        if let handoffText = SharedStore.shared.consumePendingHandoffText() {
            insertTranscriptText(handoffText, latencyMs: 0, recordToHistory: false)
        }

        if hasFullAccess {
            refreshHealthIfNeeded()
        }
    }

    func handleDisappear() {
        cancelRecording(silent: true)
    }

    func handleMemoryWarning() {
        if phase == .idle {
            recorder.teardown()
        }
    }

    func cycleMode() {
        HapticFeedback.keyTap()
        mode = mode.next
        SharedStore.shared.mode = mode
    }

    func startDictation(isHoldGesture: Bool = false) {
        guard hasFullAccess else {
            HapticFeedback.error()
            phase = .error(
                message: "Turn on Allow Full Access in Settings -> Keyboards -> LocalWhisper.",
                recovery: .openAppSettings
            )
            return
        }

        guard phase == .idle || phase.isInsertedOrError else { return }

        insertedResetTask?.cancel()
        SharedStore.shared.reload()
        mode = SharedStore.shared.mode

        let token = UUID()
        activeRecordingToken = token
        isHoldingToTalk = isHoldGesture
        elapsedSeconds = 0
        recordingStartedAt = Date()
        rawLevelHistory = Array(repeating: 0.08, count: 24)
        waveformLevels = rawLevelHistory
        phase = .starting
        HapticFeedback.startListening()

        let context = onContextBeforeCursor?().map { String($0.suffix(80)) }
        let session = ParakeetStreamSession(
            serverURL: SharedStore.shared.serverURL,
            apiToken: SharedStore.shared.apiToken,
            mode: mode,
            dictionary: SharedStore.shared.dictionary,
            context: context,
            smartSpacing: SharedStore.shared.smartSpacing,
            enableWebSocket: SharedStore.shared.useStreamingWebSocket
        )
        self.streamSession = session

        Task {
            await session.open()
        }

        recorder.startRecording()
        startElapsedTimer()
    }

    func stopAndTranscribe() {
        guard phase == .recording || phase == .starting else { return }
        stopElapsedTimer()
        HapticFeedback.stopListening()

        let currentToken = activeRecordingToken
        let (pcmData, duration) = recorder.stopRecording()
        let activeSession = streamSession
        streamSession = nil
        isHoldingToTalk = false

        guard pcmData.count >= 640 else {
            Task { await activeSession?.cancel() }
            phase = .error(message: "Too short — hold or speak a little longer.", recovery: .retry)
            scheduleIdleReset(after: 2.2)
            return
        }

        phase = .transcribing
        let currentMode = mode
        let storeSnapshotURL = SharedStore.shared.serverURL
        let storeSnapshotToken = SharedStore.shared.apiToken
        let storeSnapshotDict = SharedStore.shared.dictionary
        let storeSnapshotSpacing = SharedStore.shared.smartSpacing
        let context = onContextBeforeCursor?().map { String($0.suffix(80)) }

        Task {
            do {
                let response: TranscriptionResponse
                if let activeSession {
                    response = try await activeSession.finish()
                } else {
                    let wav = AudioWAVEncoder.encodePCM16ToWAV(pcmData: pcmData)
                    response = try await ParakeetClient.shared.transcribeWAV(
                        wavData: wav,
                        serverURL: storeSnapshotURL,
                        apiToken: storeSnapshotToken,
                        mode: currentMode,
                        dictionary: storeSnapshotDict,
                        context: context,
                        smartSpacing: storeSnapshotSpacing
                    )
                }

                guard self.activeRecordingToken == currentToken else { return }

                let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.phase = .error(message: "Didn't catch any speech.", recovery: .retry)
                    self.scheduleIdleReset(after: 2.0)
                    return
                }

                var finalInsertion = response.text
                if SharedStore.shared.autoTrailingSpace && !finalInsertion.hasSuffix(" ") && !finalInsertion.hasSuffix("\n") {
                    finalInsertion += " "
                }

                let latency = Int(round(response.inferenceMs))
                self.lastLatencyMs = latency
                self.serverStatus = .connected(pingMs: max(1, Int(round(response.totalMs - response.inferenceMs))))

                let record = DictationRecord(
                    text: trimmed,
                    rawText: response.rawText,
                    durationSeconds: max(duration, response.durationSeconds),
                    inferenceMs: response.inferenceMs,
                    mode: currentMode,
                    source: "Keyboard"
                )
                SharedStore.shared.appendHistory(record)
                self.insertTranscriptText(finalInsertion, latencyMs: latency, recordToHistory: false)
            } catch let err as ParakeetError {
                guard self.activeRecordingToken == currentToken else { return }
                HapticFeedback.error()
                if case .serverUnreachable = err {
                    self.serverStatus = .unreachable
                }
                self.phase = .error(
                    message: err.localizedDescription,
                    recovery: .openAppSettings
                )
            } catch {
                guard self.activeRecordingToken == currentToken else { return }
                HapticFeedback.error()
                self.phase = .error(message: error.localizedDescription, recovery: .retry)
            }
        }
    }

    func cancelRecording(silent: Bool = false) {
        activeRecordingToken = UUID()
        stopElapsedTimer()
        recorder.cancelRecording()
        let activeSession = streamSession
        streamSession = nil
        isHoldingToTalk = false
        if let activeSession {
            Task { await activeSession.cancel() }
        }
        if !silent {
            HapticFeedback.keyTap()
        }
        phase = .idle
    }

    func undoLastInsertion() {
        guard canUndo, lastInsertedCharCount > 0 else { return }
        HapticFeedback.keyTap()
        onDeleteBackward?(lastInsertedCharCount)
        lastInsertedCharCount = 0
        canUndo = false
        if case .inserted = phase {
            phase = .idle
        }
    }

    func insertQuickText(_ text: String) {
        HapticFeedback.keyTap()
        onInsertText?(text)
        canUndo = false
        lastInsertedCharCount = 0
    }

    func deleteOneBackward() {
        onDeleteBackward?(1)
        canUndo = false
        lastInsertedCharCount = 0
    }

    func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .none:
            phase = .idle
        case .retry:
            phase = .idle
            startDictation()
        case .openMicSetup:
            if let url = URL(string: "\(AppGroup.urlScheme)://setup-mic") {
                onOpenURL?(url)
            }
        case .openAppSettings:
            if let url = URL(string: "\(AppGroup.urlScheme)://settings") {
                onOpenURL?(url)
            }
        case .openFallbackDictation:
            if let url = URL(string: "\(AppGroup.urlScheme)://dictate") {
                onOpenURL?(url)
            }
        }
    }

    func openCompanionSettings() {
        HapticFeedback.keyTap()
        if let url = URL(string: "\(AppGroup.urlScheme)://settings") {
            onOpenURL?(url)
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "\(AppGroup.urlScheme)://setup-keyboard") {
            onOpenURL?(url)
        }
    }

    // MARK: - Private

    private func insertTranscriptText(_ text: String, latencyMs: Int, recordToHistory: Bool) {
        onInsertText?(text)
        lastInsertedCharCount = text.count
        canUndo = true
        HapticFeedback.inserted()

        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .inserted(preview: preview, latencyMs: latencyMs)
        scheduleIdleReset(after: 2.8)
    }

    private func scheduleIdleReset(after seconds: Double) {
        insertedResetTask?.cancel()
        insertedResetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if case .inserted = self.phase {
                self.phase = .idle
            } else if case .error(_, let recovery) = self.phase, recovery == .retry {
                self.phase = .idle
            }
        }
    }

    private func configureRecorderCallbacks() {
        recorder.onRecordingLive = { [weak self] _ in
            guard let self else { return }
            if self.phase == .starting {
                self.phase = .recording
            }
        }

        recorder.onPCMChunk = { [weak self] chunk, level in
            guard let self else { return }
            if self.phase == .starting {
                self.phase = .recording
            }
            self.pushAudioLevel(CGFloat(level))
            if let session = self.streamSession {
                Task {
                    await session.appendPCMChunk(chunk)
                }
            }
        }

        recorder.onAudioLevel = { [weak self] level in
            self?.pushAudioLevel(CGFloat(level))
        }

        recorder.onError = { [weak self] err in
            guard let self else { return }
            self.stopElapsedTimer()
            let active = self.streamSession
            self.streamSession = nil
            if let active {
                Task { await active.cancel() }
            }
            self.isHoldingToTalk = false
            HapticFeedback.error()
            switch err {
            case .permissionDenied:
                self.phase = .error(
                    message: "Grant microphone access once in LocalWhisper.",
                    recovery: .openMicSetup
                )
            case .startTimedOut, .micUnavailable, .webViewNotAttached:
                self.phase = .error(
                    message: err.localizedDescription,
                    recovery: .openFallbackDictation
                )
            }
        }
    }

    private func pushAudioLevel(_ level: CGFloat) {
        let clamped = max(0.06, min(1.0, level))
        // Shift outward from center for a lush, centered symmetric pulse
        var next = rawLevelHistory
        let mid = next.count / 2
        if mid > 1 {
            for i in stride(from: 0, to: mid - 1, by: 1) {
                next[i] = next[i + 1] * 0.94
            }
            for i in stride(from: next.count - 1, through: mid + 1, by: -1) {
                next[i] = next[i - 1] * 0.94
            }
        }
        let jitter = CGFloat.random(in: 0.88...1.12)
        next[mid - 1] = min(1.0, clamped * jitter)
        next[mid] = clamped
        rawLevelHistory = next
        waveformLevels = next
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.recordingStartedAt else { return }
                self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(started)))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func refreshHealthIfNeeded() {
        if let last = lastHealthCheckAt, Date().timeIntervalSince(last) < 25 {
            return
        }
        lastHealthCheckAt = Date()
        healthTask?.cancel()
        let url = SharedStore.shared.serverURL
        let token = SharedStore.shared.apiToken
        healthTask = Task {
            do {
                let res = try await ParakeetClient.shared.checkHealth(serverURL: url, apiToken: token)
                guard !Task.isCancelled else { return }
                self.serverStatus = res.ready ? .connected(pingMs: Int(round(res.pingMs))) : .unknown
            } catch {
                guard !Task.isCancelled else { return }
                self.serverStatus = .unreachable
            }
        }
    }
}

private extension KeyboardViewModel.Phase {
    var isInsertedOrError: Bool {
        switch self {
        case .inserted, .error: return true
        default: return false
        }
    }
}
