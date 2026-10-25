import SwiftUI

@main
struct ProxyHealthApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Observer queries must be registered on every launch, including background launches by HealthKit.
        if UserDefaults.standard.bool(forKey: "healthAuthorizationRequested") {
            Task { await SyncEngine.shared.startBackgroundDelivery() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        // The sync is triggered from ContentView, which also holds the dashboard and can
        // refresh the screen once the sync finishes.
        .environment(\.scenePhase, scenePhase)
    }
}
