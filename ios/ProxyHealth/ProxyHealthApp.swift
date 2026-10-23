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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isAuthorized, model.settings.isConfigured {
                Task { await model.syncNow() }
            }
        }
    }
}
