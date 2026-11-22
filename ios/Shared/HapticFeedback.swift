import UIKit

@MainActor
public enum HapticFeedback {
    public static func startListening() {
        guard SharedStore.shared.enableHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
    }

    public static func stopListening() {
        guard SharedStore.shared.enableHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.7)
    }

    public static func keyTap() {
        guard SharedStore.shared.enableHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.45)
    }

    public static func inserted() {
        guard SharedStore.shared.enableHaptics else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    public static func error() {
        guard SharedStore.shared.enableHaptics else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
}
