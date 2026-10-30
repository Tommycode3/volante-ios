import UIKit

/// Confirmations you can feel without looking.
///
/// In the car the visual channel doesn't exist and the audio one is taken by
/// the podcast: touch is the only one left free. A sharp tap when recording
/// starts says what a beep would say worse, and it doesn't cover a single
/// word.
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let sharp = UIImpactFeedbackGenerator(style: .rigid)
    private static let notice = UINotificationFeedbackGenerator()

    /// Call shortly before: it warms up the engine and removes the delay of the first tap.
    static func warmUp() {
        impact.prepare(); sharp.prepare(); notice.prepare()
    }

    /// I'm recording.
    static func listening() {
        impact.impactOccurred(intensity: 1.0)
        impact.prepare()
    }

    /// Gesture recognized.
    static func recognized() {
        sharp.impactOccurred(intensity: 0.7)
        sharp.prepare()
    }

    static func saved() {
        notice.notificationOccurred(.success)
        notice.prepare()
    }

    static func failed() {
        notice.notificationOccurred(.error)
        notice.prepare()
    }
}
