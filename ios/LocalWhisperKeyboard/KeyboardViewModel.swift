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

    enum KeyboardPage: Equatable {
        case numbers
        case symbols
        case letters
    }

    enum ShiftState: Equatable {
        case off
        case shifted
        case capsLock
    }

    var phase: Phase = .idle
    var page: KeyboardPage = .numbers
    var shiftState: ShiftState = .shifted
    var hasFullAccess: Bool = false
    var serverStatus: ServerStatus = .unknown
    var waveformLevels: [CGFloat] = Array(repeating: 0.12, count: 18)
    var elapsedSeconds: Int = 0
    var canUndo: Bool = false
    var lastLatencyMs: Int?
    var mode: TranscriptionMode = SharedStore.shared.mode
    var showNeedsInputSwitchKey: Bool = false

    private let recorder = WebViewAudioRecorder()
    private var streamSession: ParakeetStreamSession?
    private var elapsedTimer: Timer?
    private var insertedResetTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var lastHealthCheckAt: Date?
    private var recordingStartedAt: Date?
    private var lastInsertedCharCount: Int = 0
    private var rawLevelHistory: [CGFloat] = Array(repeating: 0.10, count: 18)
    private var activeRecordingToken = UUID()
    private var lastShiftTapAt: Date?

    // Callbacks provided by KeyboardViewController
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: ((Int) -> Void)?
    var onContextBeforeCursor: (() -> String?)?
    var onOpenURL: ((URL) -> Void)?
    var onAdvanceKeyboard: (() -> Void)?

    init() {
        configureRecorderCallbacks()
    }

    var isActivelyRecording: Bool {
        phase == .starting || phase == .recording
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
        updateAutoShift()

        if hasFullAccess && SharedStore.shared.prewarmWebView {
            recorder.prewarm()
        }

        // Check if user returned from companion-app fallback dictation
        if let handoffText = SharedStore.shared.consumePendingHandoffText() {
            insertTranscriptText(handoffText, latencyMs: 0)
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

    func toggleDictation() {
        switch phase {
        case .starting, .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        case .idle, .inserted, .error:
            startDictation()
        }
    }

    func startDictation() {
        guard hasFullAccess else {
            HapticFeedback.error()
            phase = .error(
                message: "Enable Allow Full Access in Settings → Keyboards → LocalWhisper.",
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
        elapsedSeconds = 0
        recordingStartedAt = Date()
        rawLevelHistory = Array(repeating: 0.12, count: 18)
        waveformLevels = rawLevelHistory
        phase = .starting
        HapticFeedback.startListening()

        let context = onContextBeforeCursor?().map { String($0.suffix(80)) }
        let localOverrides = SharedStore.shared.dictionaryHasUnsyncedChanges ? SharedStore.shared.dictionary : []
        let session = ParakeetStreamSession(
            serverURL: SharedStore.shared.serverURL,
            apiToken: SharedStore.shared.apiToken,
            mode: mode,
            dictionary: localOverrides,
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

        guard pcmData.count >= 640 else {
            Task { await activeSession?.cancel() }
            phase = .error(message: "Too short — try speaking a little longer.", recovery: .retry)
            scheduleIdleReset(after: 2.2)
            return
        }

        phase = .transcribing
        let currentMode = mode
        let storeSnapshotURL = SharedStore.shared.serverURL
        let storeSnapshotToken = SharedStore.shared.apiToken
        let storeSnapshotDict = SharedStore.shared.dictionaryHasUnsyncedChanges ? SharedStore.shared.dictionary : []
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
                self.insertTranscriptText(finalInsertion, latencyMs: latency)
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

    // MARK: - Key Input

    func insertCharacter(_ char: String) {
        HapticFeedback.keyTap()
        let output: String
        if page == .letters {
            output = (shiftState == .off) ? char.lowercased() : char.uppercased()
            if shiftState == .shifted {
                shiftState = .off
            }
        } else {
            output = char
        }
        onInsertText?(output)
        canUndo = false
        lastInsertedCharCount = 0
        if char == "\n" {
            updateAutoShift()
        }
    }

    func insertSpace() {
        HapticFeedback.keyTap()
        onInsertText?(" ")
        canUndo = false
        lastInsertedCharCount = 0
        updateAutoShift()
    }

    func insertReturn() {
        HapticFeedback.keyTap()
        onInsertText?("\n")
        canUndo = false
        lastInsertedCharCount = 0
        if shiftState != .capsLock {
            shiftState = .shifted
        }
    }

    func deleteOneBackward() {
        onDeleteBackward?(1)
        canUndo = false
        lastInsertedCharCount = 0
    }

    func toggleShift() {
        HapticFeedback.keyTap()
        let now = Date()
        if let last = lastShiftTapAt, now.timeIntervalSince(last) < 0.32, shiftState == .shifted {
            shiftState = .capsLock
            lastShiftTapAt = nil
            return
        }
        lastShiftTapAt = now
        switch shiftState {
        case .off:
            shiftState = .shifted
        case .shifted, .capsLock:
            shiftState = .off
        }
    }

    func switchPage(_ target: KeyboardPage) {
        HapticFeedback.keyTap()
        page = target
        if target == .letters {
            updateAutoShift()
        }
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

    // MARK: - Private

    private func updateAutoShift() {
        guard shiftState != .capsLock else { return }
        let ctx = onContextBeforeCursor?() ?? ""
        if ctx.isEmpty || ctx.hasSuffix("\n") || ctx.hasSuffix(". ") || ctx.hasSuffix("! ") || ctx.hasSuffix("? ") {
            shiftState = .shifted
        } else {
            shiftState = .off
        }
    }

    private func insertTranscriptText(_ text: String, latencyMs: Int) {
        onInsertText?(text)
        lastInsertedCharCount = text.count
        canUndo = true
        HapticFeedback.inserted()

        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .inserted(preview: preview, latencyMs: latencyMs)
        scheduleIdleReset(after: 2.5)
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
        let clamped = max(0.08, min(1.0, level))
        var next = rawLevelHistory
        let mid = next.count / 2
        if mid > 1 {
            for i in stride(from: 0, to: mid - 1, by: 1) {
                next[i] = next[i + 1] * 0.92
            }
            for i in stride(from: next.count - 1, through: mid + 1, by: -1) {
                next[i] = next[i - 1] * 0.92
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
