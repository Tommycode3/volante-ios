import CoreMotion
import Observation

/// Figures out when you CAN'T listen.
///
/// Proactivity is what kills in-car assistants: they speak at the wrong
/// moment three times and you switch them off for good. Roundabout,
/// overtaking, merging, braking: silence. Straight road at constant speed:
/// free window. The accelerometer and gyroscope are enough — no location
/// permission, no GPS drain.
///
/// It uses gravity-free acceleration and the magnitude of rotation, so it
/// doesn't matter how the phone is oriented in the mount.
@MainActor
@Observable
final class DrivingContext {

    private(set) var isManeuvering = false
    private(set) var acceleration: Double = 0      // g, without gravity
    private(set) var rotation: Double = 0          // rad/s
    private(set) var available = false

    /// True when it's reasonable to speak without being asked.
    var canInterrupt: Bool {
        guard available else { return true }       // without data, nothing is blocked
        return Date().timeIntervalSince(lastManeuver) > calmSeconds
    }

    var diagnostics: Diagnostics?

    private let motion = CMMotionManager()
    private var lastManeuver = Date.distantPast
    private let accelThreshold = 0.22              // g
    private let rotationThreshold = 0.30           // rad/s, ~17°/s
    private let calmSeconds: Double = 4

    func start() {
        guard motion.isDeviceMotionAvailable else {
            diagnostics?.log("guida", "sensori di movimento non disponibili")
            return
        }
        guard !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            MainActor.assumeIsolated { self.consume(d) }
        }
        available = true
        diagnostics?.log("guida", "sensori attivi")
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        available = false
    }

    private func consume(_ d: CMDeviceMotion) {
        let a = d.userAcceleration
        let r = d.rotationRate
        acceleration = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        rotation = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()

        let busy = acceleration > accelThreshold || rotation > rotationThreshold
        if busy { lastManeuver = Date() }

        // Only the edge is logged, otherwise the log fills up with nothing.
        let nowManeuvering = !canInterrupt
        if nowManeuvering != isManeuvering {
            isManeuvering = nowManeuvering
            if nowManeuvering {
                diagnostics?.log("guida", String(format: "manovra — %.2f g, %.2f rad/s",
                                                 acceleration, rotation))
            }
        }
    }
}
