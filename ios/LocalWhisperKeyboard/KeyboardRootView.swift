import SwiftUI
import UIKit

struct KeyboardRootView: View {
    @Bindable var viewModel: KeyboardViewModel
    let nextKeyboardAction: (UIButton, UIEvent) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var backspaceTimer: Timer?

    private let coral = Color(red: 0.94, green: 0.33, blue: 0.22)
    private let emerald = Color(red: 0.16, green: 0.76, blue: 0.45)

    private var keyFill: Color {
        colorScheme == .dark
            ? Color(red: 0.23, green: 0.24, blue: 0.27)
            : Color.white
    }

    private var modifierFill: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)
            : Color(red: 0.91, green: 0.915, blue: 0.93)
    }

    private var keyShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.45)
            : Color.black.opacity(0.14)
    }

    private var primaryInk: Color {
        colorScheme == .dark ? Color.white : Color(red: 0.08, green: 0.09, blue: 0.11)
    }

    private var secondaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.60) : Color(red: 0.38, green: 0.40, blue: 0.46)
    }

    private var recordIdleFill: Color {
        colorScheme == .dark ? Color(red: 0.95, green: 0.95, blue: 0.93) : Color(red: 0.10, green: 0.11, blue: 0.13)
    }

    private var recordIdleIcon: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.09, blue: 0.11) : Color.white
    }

    private static let numberRow1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private static let numberRow2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
    private static let symbolRow1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    private static let symbolRow2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
    private static let punctRow3 = [".", ",", "?", "!", "'"]

    private static let letterRow1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let letterRow2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let letterRow3 = ["z", "x", "c", "v", "b", "n", "m"]

    var body: some View {
        VStack(spacing: 8) {
            topToolbar
                .frame(height: 46)

            keyGrid
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(height: 278)
    }

    // MARK: - Top Toolbar (Wispr Flow style)

    private var topToolbar: some View {
        HStack(spacing: 8) {
            // Left: Cancel during recording, otherwise Settings Link to LocalWhisper app
            if viewModel.isActivelyRecording {
                Button {
                    viewModel.cancelRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryInk)
                        .frame(width: 40, height: 40)
                        .background(keyFill, in: Circle())
                        .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel recording")
            } else {
                settingsAppLink
            }

            // Center / Right cluster adapts smoothly to state
            switch viewModel.phase {
            case .starting, .recording:
                recordingPill
                recordToggleButton

            case .transcribing:
                transcribingPill
                recordToggleButton

            case .error(let message, let recovery):
                errorBanner(message: message, recovery: recovery)
                recordToggleButton

            case .idle, .inserted:
                Spacer(minLength: 4)

                if case .inserted(_, let ms) = viewModel.phase, ms > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(emerald)
                        Text("\(ms)ms")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(secondaryInk)
                    }
                    .transition(.opacity)
                }

                // Undo button next to style picker
                Button {
                    viewModel.undoLastInsertion()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(viewModel.canUndo ? primaryInk : secondaryInk.opacity(0.45))
                        .frame(width: 38, height: 38)
                        .background(keyFill.opacity(viewModel.canUndo ? 1.0 : 0.65), in: Circle())
                        .shadow(color: viewModel.canUndo ? keyShadow : .clear, radius: 0.5, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canUndo)
                .accessibilityLabel("Undo last dictation")

                // Style picker pill ("Clean" / "Casual" / "very casual" / "Notes" / "Raw")
                Button {
                    viewModel.cycleMode()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 7, height: 7)
                        Text(viewModel.mode.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(primaryInk)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(keyFill, in: Capsule())
                    .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Style: \(viewModel.mode.title)")

                recordToggleButton
            }
        }
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.18), value: viewModel.phase)
        .animation(.easeOut(duration: 0.15), value: viewModel.canUndo)
    }

    private var settingsAppLink: some View {
        Group {
            if let settingsURL = URL(string: "\(AppGroup.urlScheme)://settings") {
                // SwiftUI Link uses Apple's extension-safe URL opener on iOS 18+;
                // simultaneous tap fallback also triggers extensionContext.open.
                Link(destination: settingsURL) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(primaryInk)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open LocalWhisper Settings")
            } else {
                Button {
                    viewModel.openCompanionSettings()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(primaryInk)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recordToggleButton: some View {
        Button {
            viewModel.toggleDictation()
        } label: {
            ZStack {
                Circle()
                    .fill(viewModel.isActivelyRecording ? coral : recordIdleFill)
                    .frame(width: 42, height: 42)
                    .shadow(
                        color: viewModel.isActivelyRecording ? coral.opacity(0.38) : keyShadow,
                        radius: viewModel.isActivelyRecording ? 6 : 1,
                        x: 0,
                        y: 1
                    )

                if viewModel.phase == .transcribing {
                    ProgressView()
                        .tint(recordIdleIcon)
                        .scaleEffect(0.85)
                } else if viewModel.isActivelyRecording {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(recordIdleIcon)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.phase == .transcribing)
        .accessibilityLabel(viewModel.isActivelyRecording ? "Stop dictation" : "Start dictation")
    }

    private var recordingPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coral)
                .frame(width: 7, height: 7)

            WaveformView(
                levels: viewModel.waveformLevels,
                tint: coral,
                barWidth: 2.8,
                spacing: 2.5,
                minHeight: 4,
                maxHeight: 22,
                isPulsing: viewModel.phase == .starting
            )
            .frame(maxWidth: .infinity)

            Text(viewModel.phase == .starting ? "…" : formattedElapsed)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(secondaryInk)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(keyFill, in: Capsule())
        .overlay(Capsule().stroke(coral.opacity(0.4), lineWidth: 1))
    }

    private var transcribingPill: some View {
        HStack(spacing: 8) {
            WaveformView(
                levels: Array(repeating: 0.45, count: 10),
                tint: coral,
                barWidth: 2.6,
                spacing: 2.5,
                minHeight: 4,
                maxHeight: 18,
                isPulsing: true
            )
            Text("Transcribing…")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(primaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(keyFill, in: Capsule())
        .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
    }

    private func errorBanner(message: String, recovery: KeyboardViewModel.RecoveryAction) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(primaryInk)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 2)

            if recovery == .openAppSettings || recovery == .openMicSetup {
                if let url = URL(string: "\(AppGroup.urlScheme)://\(recovery == .openMicSetup ? "setup-mic" : "settings")") {
                    Link("Fix", destination: url)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(coral, in: Capsule())
                }
            } else {
                Button {
                    viewModel.phase = .idle
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(secondaryInk)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(keyFill, in: Capsule())
        .overlay(Capsule().stroke(coral.opacity(0.45), lineWidth: 1))
    }

    private var statusDotColor: Color {
        if !viewModel.hasFullAccess { return Color.orange }
        switch viewModel.serverStatus {
        case .connected: return emerald
        case .unreachable: return coral
        case .unknown: return secondaryInk.opacity(0.5)
        }
    }

    // MARK: - Key Grid (Numbers & Symbols Primary + #+= + ABC)

    @ViewBuilder
    private var keyGrid: some View {
        switch viewModel.page {
        case .numbers:
            VStack(spacing: 9) {
                characterRow(Self.numberRow1)
                characterRow(Self.numberRow2)
                HStack(spacing: 6) {
                    modifierKey(label: "#+=", width: 46) {
                        viewModel.switchPage(.symbols)
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.punctRow3, id: \.self) { ch in
                            characterKey(ch, fontSize: 22)
                        }
                    }
                    backspaceKey(width: 46)
                }
                bottomSpaceRow(leftLabel: "ABC") {
                    viewModel.switchPage(.letters)
                }
            }

        case .symbols:
            VStack(spacing: 9) {
                characterRow(Self.symbolRow1)
                characterRow(Self.symbolRow2)
                HStack(spacing: 6) {
                    modifierKey(label: "123", width: 46) {
                        viewModel.switchPage(.numbers)
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.punctRow3, id: \.self) { ch in
                            characterKey(ch, fontSize: 22)
                        }
                    }
                    backspaceKey(width: 46)
                }
                bottomSpaceRow(leftLabel: "ABC") {
                    viewModel.switchPage(.letters)
                }
            }

        case .letters:
            VStack(spacing: 9) {
                characterRow(Self.letterRow1, isLetterRow: true)
                characterRow(Self.letterRow2, isLetterRow: true)
                    .padding(.horizontal, 16)
                HStack(spacing: 6) {
                    shiftKey(width: 44)
                    HStack(spacing: 5) {
                        ForEach(Self.letterRow3, id: \.self) { ch in
                            let display = viewModel.shiftState == .off ? ch : ch.uppercased()
                            characterKey(display, fontSize: 21)
                        }
                    }
                    backspaceKey(width: 44)
                }
                bottomSpaceRow(leftLabel: "123") {
                    viewModel.switchPage(.numbers)
                }
            }
        }
    }

    private func characterRow(_ keys: [String], isLetterRow: Bool = false) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { ch in
                let label = (isLetterRow && viewModel.shiftState != .off) ? ch.uppercased() : ch
                characterKey(label, fontSize: isLetterRow ? 21 : 22)
            }
        }
    }

    private func characterKey(_ label: String, fontSize: CGFloat) -> some View {
        Button {
            viewModel.insertCharacter(label)
        } label: {
            Text(label)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(primaryInk)
                .frame(maxWidth: .infinity)
                .frame(height: 43)
                .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
        }
        .buttonStyle(KeyPressStyle())
    }

    private func modifierKey(label: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(primaryInk)
                .frame(width: width, height: 43)
                .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
        }
        .buttonStyle(KeyPressStyle())
    }

    private func shiftKey(width: CGFloat) -> some View {
        let isActive = viewModel.shiftState != .off
        let symbol: String = {
            switch viewModel.shiftState {
            case .off: return "shift"
            case .shifted: return "shift.fill"
            case .capsLock: return "capslock.fill"
            }
        }()

        return Button {
            viewModel.toggleShift()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? (colorScheme == .dark ? .black : .white) : primaryInk)
                .frame(width: width, height: 43)
                .background(
                    isActive ? primaryInk : modifierFill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel("Shift")
    }

    private func backspaceKey(width: CGFloat) -> some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(primaryInk)
            .frame(width: width, height: 43)
            .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if backspaceTimer == nil {
                            HapticFeedback.keyTap()
                            viewModel.deleteOneBackward()
                            backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { _ in
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
    }

    private func bottomSpaceRow(leftLabel: String, leftAction: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if viewModel.showNeedsInputSwitchKey {
                GlobeKeyButton(tint: primaryInk, background: keyFill, action: nextKeyboardAction)
                    .frame(width: 42, height: 43)
                    .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
            }

            Button(action: leftAction) {
                Text(leftLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(primaryInk)
                    .frame(width: viewModel.showNeedsInputSwitchKey ? 62 : 84, height: 43)
                    .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
            }
            .buttonStyle(KeyPressStyle())

            Button {
                viewModel.insertSpace()
            } label: {
                Text("LocalWhisper")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(primaryInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 43)
                    .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
            }
            .buttonStyle(KeyPressStyle())
            .accessibilityLabel("Space")

            Button {
                viewModel.insertReturn()
            } label: {
                Image(systemName: "return.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(primaryInk)
                    .frame(width: 84, height: 43)
                    .background(keyFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: keyShadow, radius: 0.5, x: 0, y: 1)
            }
            .buttonStyle(KeyPressStyle())
            .accessibilityLabel("Return")
        }
    }

    private var formattedElapsed: String {
        let mins = viewModel.elapsedSeconds / 60
        let secs = viewModel.elapsedSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
        button.layer.cornerRadius = 10
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
