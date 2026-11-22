import SwiftUI
import UIKit

struct KeyboardRootView: View {
    @Bindable var viewModel: KeyboardViewModel
    let nextKeyboardAction: (UIButton, UIEvent) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var pressBeganAt: Date?
    @State private var isPressingPill = false
    @State private var backspaceTimer: Timer?

    private var coral: Color { Color(red: 0.94, green: 0.33, blue: 0.22) }
    private var emerald: Color { Color(red: 0.16, green: 0.76, blue: 0.45) }

    private var surfaceFill: Color {
        colorScheme == .dark
            ? Color(red: 0.145, green: 0.15, blue: 0.175)
            : Color.white
    }

    private var subtleFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    private var borderStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    private var primaryInk: Color {
        colorScheme == .dark ? Color.white : Color(red: 0.10, green: 0.11, blue: 0.13)
    }

    private var secondaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.60) : Color(red: 0.38, green: 0.40, blue: 0.45)
    }

    var body: some View {
        VStack(spacing: 10) {
            topUtilityBar
            centerStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomControlBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(height: 264)
    }

    // MARK: - Top Bar

    private var topUtilityBar: some View {
        HStack(spacing: 8) {
            // Connection & Mode selector pill
            Button {
                viewModel.cycleMode()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Image(systemName: viewModel.mode.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryInk)
                    Text(viewModel.mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryInk)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(surfaceFill, in: Capsule())
                .overlay(Capsule().stroke(borderStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if viewModel.canUndo {
                Button {
                    viewModel.undoLastInsertion()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Undo")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(primaryInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(subtleFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            Spacer(minLength: 4)

            if let ms = viewModel.lastLatencyMs, viewModel.phase == .idle {
                Text("\(ms)ms")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(subtleFill, in: Capsule())
            }

            Button {
                viewModel.openCompanionSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .frame(width: 32, height: 30)
                    .background(subtleFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("LocalWhisper Settings")
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.canUndo)
    }

    private var statusDotColor: Color {
        if !viewModel.hasFullAccess { return Color.orange }
        switch viewModel.serverStatus {
        case .connected: return emerald
        case .unreachable: return coral
        case .unknown: return secondaryInk.opacity(0.6)
        }
    }

    // MARK: - Center Stage

    @ViewBuilder
    private var centerStage: some View {
        if !viewModel.hasFullAccess {
            fullAccessRequiredView
        } else {
            switch viewModel.phase {
            case .idle:
                idleDictateView
            case .starting, .recording:
                activeRecordingView
            case .transcribing:
                transcribingView
            case .inserted(let preview, let latencyMs):
                insertedConfirmationView(preview: preview, latencyMs: latencyMs)
            case .error(let message, let recovery):
                errorRecoveryView(message: message, recovery: recovery)
            }
        }
    }

    private var fullAccessRequiredView: some View {
        VStack(spacing: 10) {
            Text("Enable Full Access to dictate")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryInk)
            Text("Settings → Keyboards → LocalWhisper → Allow Full Access")
                .font(.system(size: 12))
                .foregroundStyle(secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button {
                viewModel.openSystemSettings()
            } label: {
                Text("Open Setup Guide")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(coral, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var idleDictateView: some View {
        VStack(spacing: 12) {
            dictateTriggerPill
            Text(idleCaption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryInk)
        }
    }

    private var idleCaption: String {
        switch viewModel.serverStatus {
        case .connected(let pingMs):
            return "Tap or hold to speak · Mac mini (\(pingMs)ms)"
        case .unreachable:
            return "Mac mini offline · check Tailscale"
        case .unknown:
            return "Tap or hold to speak · Parakeet MLX"
        }
    }

    private var dictateTriggerPill: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(coral)
                    .frame(width: 42, height: 42)
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dictate")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primaryInk)
                Text("Local Parakeet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryInk)
            }
            .padding(.trailing, 8)
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .background(surfaceFill, in: Capsule())
        .overlay(
            Capsule()
                .stroke(isPressingPill ? coral.opacity(0.7) : borderStroke, lineWidth: isPressingPill ? 1.5 : 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
            radius: 10,
            x: 0,
            y: 4
        )
        .scaleEffect(isPressingPill ? 0.96 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isPressingPill)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressingPill {
                        isPressingPill = true
                        pressBeganAt = Date()
                        viewModel.startDictation(isHoldGesture: true)
                    }
                }
                .onEnded { _ in
                    isPressingPill = false
                    let held = pressBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressBeganAt = nil
                    if held >= 0.42 {
                        // Push-to-talk release: stop and transcribe immediately
                        viewModel.stopAndTranscribe()
                    } else {
                        // Quick tap: stay in hands-free recording mode
                        viewModel.isHoldingToTalk = false
                    }
                }
        )
        .accessibilityLabel("Dictate")
        .accessibilityHint("Tap to start hands-free dictation, or press and hold to talk")
    }

    private var activeRecordingView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Cancel button
                Button {
                    viewModel.cancelRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryInk)
                        .frame(width: 46, height: 46)
                        .background(surfaceFill, in: Circle())
                        .overlay(Circle().stroke(borderStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel recording")

                // Live Waveform + Timer container
                VStack(spacing: 6) {
                    WaveformView(
                        levels: viewModel.waveformLevels,
                        tint: coral,
                        barWidth: 3.5,
                        spacing: 3,
                        minHeight: 5,
                        maxHeight: 36,
                        isPulsing: viewModel.phase == .starting
                    )

                    HStack(spacing: 6) {
                        Circle()
                            .fill(coral)
                            .frame(width: 6, height: 6)
                        Text(viewModel.phase == .starting ? "Listening…" : formattedElapsed)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(surfaceFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(coral.opacity(0.35), lineWidth: 1.2)
                )

                // Done / Transcribe button
                Button {
                    viewModel.stopAndTranscribe()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(coral, in: Circle())
                        .shadow(color: coral.opacity(0.35), radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish and transcribe")
            }

            Text(viewModel.isHoldingToTalk ? "Release to insert" : "Tap ↑ when finished")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryInk)
        }
    }

    private var transcribingView: some View {
        VStack(spacing: 12) {
            WaveformView(
                levels: Array(repeating: 0.4, count: 18),
                tint: primaryInk.opacity(0.75),
                barWidth: 3.5,
                spacing: 4,
                minHeight: 6,
                maxHeight: 28,
                isPulsing: true
            )
            Text("Transcribing on Mac mini…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondaryInk)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(surfaceFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private func insertedConfirmationView(preview: String, latencyMs: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(emerald)
                Text(preview)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if latencyMs > 0 {
                    Text("\(latencyMs)ms")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(emerald)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(emerald.opacity(0.35), lineWidth: 1)
            )
            .onTapGesture {
                viewModel.startDictation()
            }

            Text("Tap again to keep dictating")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryInk)
        }
    }

    private func errorRecoveryView(message: String, recovery: KeyboardViewModel.RecoveryAction) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(coral)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryInk)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(coral.opacity(0.35), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button {
                    viewModel.phase = .idle
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryInk)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(subtleFill, in: Capsule())
                }
                .buttonStyle(.plain)

                if recovery != .none {
                    Button {
                        viewModel.performRecovery(recovery)
                    } label: {
                        Text(recoveryButtonTitle(for: recovery))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(coral, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func recoveryButtonTitle(for action: KeyboardViewModel.RecoveryAction) -> String {
        switch action {
        case .none: return "OK"
        case .retry: return "Try Again"
        case .openMicSetup: return "Grant Mic Access"
        case .openAppSettings: return "Open Settings"
        case .openFallbackDictation: return "Dictate in App"
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomControlBar: some View {
        HStack(spacing: 7) {
            if viewModel.showNeedsInputSwitchKey {
                GlobeKeyButton(tint: primaryInk, background: subtleFill, action: nextKeyboardAction)
                    .frame(width: 42, height: 38)
            }

            quickKey(".")
            quickKey(",")

            Button {
                viewModel.insertQuickText(" ")
            } label: {
                Text("space")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(surfaceFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(borderStroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            quickKey("?")

            // Backspace with press-and-hold rapid repeat
            Image(systemName: "delete.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(primaryInk)
                .frame(width: 44, height: 38)
                .background(subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if backspaceTimer == nil {
                                HapticFeedback.keyTap()
                                viewModel.deleteOneBackward()
                                backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { _ in
                                    Task { @MainActor in
                                        viewModel.deleteOneBackward()
                                    }
                                }
                            }
                        }
                        .onEnded { _ in
                            backspaceTimer?.invalidate()
                            backspaceTimer = nil
                        }
                )
                .accessibilityLabel("Backspace")

            Button {
                viewModel.insertQuickText("\n")
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryInk)
                    .frame(width: 44, height: 38)
                    .background(subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return")
        }
    }

    private func quickKey(_ char: String) -> some View {
        Button {
            viewModel.insertQuickText(char)
        } label: {
            Text(char)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(primaryInk)
                .frame(width: 34, height: 38)
                .background(surfaceFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(borderStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var formattedElapsed: String {
        let mins = viewModel.elapsedSeconds / 60
        let secs = viewModel.elapsedSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Native UIButton wrapper so iOS handles both single-tap next keyboard and long-press keyboard picker.
private struct GlobeKeyButton: UIViewRepresentable {
    let tint: Color
    let background: Color
    let action: (UIButton, UIEvent) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        button.layer.cornerRadius = 9
        button.clipsToBounds = true
        button.accessibilityLabel = "Next Keyboard"
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleTouch(_:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.backgroundColor = UIColor(background)
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: (UIButton, UIEvent) -> Void

        init(action: @escaping (UIButton, UIEvent) -> Void) {
            self.action = action
        }

        @objc func handleTouch(_ sender: UIButton, with event: UIEvent) {
            action(sender, event)
        }
    }
}
