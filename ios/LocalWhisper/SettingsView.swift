import SwiftUI

struct SettingsView: View {
    @Bindable private var store = SharedStore.shared
    @State private var pingResult: String?
    @State private var pingSucceeded = false
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("https://your-mac.ts.net/parakeet", text: $store.serverURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bearer Token (optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        SecureField("Leave empty if using Tailnet-only auth", text: $store.apiToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Mac mini Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let pingResult {
                                Text(pingResult)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(pingSucceeded ? .green : .red)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .disabled(isTesting)
                } header: {
                    Text("Mac mini Server")
                } footer: {
                    Text("Preconfigured for your Mac mini over Tailscale Serve HTTPS. Works from anywhere on Wi-Fi or cellular while Tailscale is connected.")
                }

                Section("Transcription Style") {
                    Picker("Default Mode", selection: $store.mode) {
                        ForEach(TranscriptionMode.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.title)
                            }
                            .tag(mode)
                        }
                    }
                    Text(store.mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Live WebSocket Streaming", isOn: $store.useStreamingWebSocket)
                    Toggle("Smart Context Spacing & Casing", isOn: $store.smartSpacing)
                    Toggle("Auto-insert Trailing Space", isOn: $store.autoTrailingSpace)
                }

                Section {
                    Toggle("Prewarm In-Keyboard Mic", isOn: $store.prewarmWebView)
                    Toggle("Haptic Feedback", isOn: $store.enableHaptics)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Prewarming keeps the invisible WebKit mic bridge ready when the keyboard opens so recording starts faster without ever leaving your app.")
                }

                Section("Diagnostics") {
                    LabeledContent("App Group") {
                        Text(store.isAppGroupActive ? "Active" : "Fallback")
                            .foregroundStyle(store.isAppGroupActive ? .green : .orange)
                    }
                    LabeledContent("Suite ID") {
                        Text(AppGroup.identifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !store.lastDiagnostic.isEmpty {
                        LabeledContent("Last Mic Timing") {
                            Text(store.lastDiagnostic)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Reset Server URL to Tailscale Default") {
                        store.serverURL = AppGroup.defaultServerURL
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let res = try await ParakeetClient.shared.checkHealth(
                serverURL: store.serverURL,
                apiToken: store.apiToken
            )
            pingSucceeded = res.ready
            pingResult = res.ready ? "OK · \(Int(round(res.pingMs)))ms" : "Loading model…"
        } catch {
            pingSucceeded = false
            pingResult = "Failed"
        }
    }
}
