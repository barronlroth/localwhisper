import AVFoundation
import SwiftUI

struct ContentView: View {
    @Bindable var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.selectedTab) {
            FlowHomeView(router: router)
                .tabItem {
                    Label("Flow", systemImage: "waveform")
                }
                .tag(AppRouter.Tab.flow)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppRouter.Tab.history)

            DictionaryView()
                .tabItem {
                    Label("Dictionary", systemImage: "character.book.closed")
                }
                .tag(AppRouter.Tab.dictionary)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(AppRouter.Tab.settings)
        }
        .tint(Color("AccentColor"))
        .sheet(isPresented: $router.showFallbackDictation) {
            FallbackDictationSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SharedStore.shared.reload()
            }
        }
    }
}

/// Optional fallback recorder when opened via `localwhisper://dictate`.
/// Records natively with AVAudioEngine, transcribes on Mac mini, and stages the result
/// in the App Group so switching back inserts it automatically.
private struct FallbackDictationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = NativeAudioRecorder()
    @State private var streamSession: ParakeetStreamSession?
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var levels: [CGFloat] = Array(repeating: 0.08, count: 24)
    @State private var resultText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                if !resultText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text(resultText)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Text("Copied & queued for your keyboard — swipe back to insert.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    WaveformView(
                        levels: levels,
                        tint: Color("AccentColor"),
                        barWidth: 4,
                        spacing: 4,
                        minHeight: 6,
                        maxHeight: 54,
                        isPulsing: isTranscribing
                    )

                    Text(statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    if isRecording {
                        stopAndTranscribe()
                    } else {
                        startRecording()
                    }
                } label: {
                    Label(
                        isRecording ? "Stop & Transcribe" : "Record Again",
                        systemImage: isRecording ? "stop.fill" : "mic.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTranscribing)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle("Quick Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        recorder.cancelRecording()
                        dismiss()
                    }
                }
            }
            .onAppear {
                startRecording()
            }
            .onDisappear {
                recorder.cancelRecording()
            }
        }
    }

    private var statusText: String {
        if isTranscribing { return "Transcribing on Mac mini…" }
        if isRecording { return "Listening…" }
        return "Ready"
    }

    private func startRecording() {
        errorMessage = nil
        resultText = ""

        let store = SharedStore.shared
        let session = ParakeetStreamSession(
            serverURL: store.serverURL,
            apiToken: store.apiToken,
            mode: store.mode,
            dictionary: store.dictionary,
            context: nil,
            smartSpacing: false,
            enableWebSocket: store.useStreamingWebSocket
        )
        self.streamSession = session

        recorder.onPCMChunk = { chunk, level in
            var next = levels
            next.removeFirst()
            next.append(max(0.08, CGFloat(level)))
            levels = next
            Task { await session.appendPCMChunk(chunk) }
        }

        Task { await session.open() }

        do {
            try recorder.startRecording()
            isRecording = true
            HapticFeedback.startListening()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopAndTranscribe() {
        let (_, duration) = recorder.stopRecording()
        isRecording = false
        isTranscribing = true
        HapticFeedback.stopListening()

        let activeSession = streamSession
        streamSession = nil

        Task {
            do {
                guard let activeSession else { return }
                let response = try await activeSession.finish()
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                UIPasteboard.general.string = text
                SharedStore.shared.setPendingHandoffText(text)
                SharedStore.shared.appendHistory(
                    DictationRecord(
                        text: text,
                        rawText: response.rawText,
                        durationSeconds: max(duration, response.durationSeconds),
                        inferenceMs: response.inferenceMs,
                        mode: SharedStore.shared.mode,
                        source: "App Handoff"
                    )
                )
                resultText = text
                isTranscribing = false
                HapticFeedback.inserted()
            } catch {
                errorMessage = error.localizedDescription
                isTranscribing = false
                HapticFeedback.error()
            }
        }
    }
}
