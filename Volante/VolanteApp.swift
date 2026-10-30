import SwiftUI

@main
struct VolanteApp: App {
    @State private var app = AppModel()

    init() { AudioSessionManager.shared.configure() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                // Always dark: you drive in the evening, and a white screen on a mount is
                // a light source in your face.
                .preferredColorScheme(.dark)
                .tint(.orange)
                .task { await app.bootstrap() }
        }
    }
}

func hhmmss(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        : String(format: "%d:%02d", t / 60, t % 60)
}
