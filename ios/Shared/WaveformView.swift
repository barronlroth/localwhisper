import SwiftUI

/// Organic Wispr Flow–style symmetric live audio waveform visualizer.
public struct WaveformView: View {
    public let levels: [CGFloat]
    public var tint: Color = Color(red: 0.94, green: 0.33, blue: 0.22)
    public var barWidth: CGFloat = 3.5
    public var spacing: CGFloat = 3.5
    public var minHeight: CGFloat = 4
    public var maxHeight: CGFloat = 34
    public var isPulsing: Bool = false

    @State private var pulsePhase: Double = 0

    public init(
        levels: [CGFloat],
        tint: Color = Color(red: 0.94, green: 0.33, blue: 0.22),
        barWidth: CGFloat = 3.5,
        spacing: CGFloat = 3.5,
        minHeight: CGFloat = 4,
        maxHeight: CGFloat = 34,
        isPulsing: Bool = false
    ) {
        self.levels = levels
        self.tint = tint
        self.barWidth = barWidth
        self.spacing = spacing
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.isPulsing = isPulsing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let centerWeight = envelopeWeight(index: index, count: levels.count)
                let height = computedHeight(level: level, weight: centerWeight, index: index)
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.45 + 0.55 * Double(centerWeight)))
                    .frame(width: barWidth, height: height)
                    .animation(.interpolatingSpring(stiffness: 280, damping: 22), value: level)
            }
        }
        .frame(height: maxHeight)
        .onAppear {
            if isPulsing {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsePhase = 1
                }
            }
        }
    }

    private func envelopeWeight(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 1.0 }
        let normalized = abs(CGFloat(index) - CGFloat(count - 1) / 2.0) / (CGFloat(count - 1) / 2.0)
        return max(0.32, 1.0 - pow(normalized, 1.6) * 0.65)
    }

    private func computedHeight(level: CGFloat, weight: CGFloat, index: Int) -> CGFloat {
        if isPulsing {
            let wave = 0.25 + 0.35 * sin(Double(index) * 0.55 + pulsePhase * .pi * 2)
            return minHeight + (maxHeight - minHeight) * CGFloat(abs(wave)) * weight
        }
        let clamped = max(0, min(1, level))
        return minHeight + (maxHeight - minHeight) * clamped * weight
    }
}
