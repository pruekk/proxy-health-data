import Foundation
import WatchConnectivity

/// Whether there is actually a watch to send a workout to.
///
/// `WorkoutScheduler.isSupported` does not answer this. It is true on an iPhone with no watch
/// paired at all — verified on the simulator, where scheduling then "succeeds" and
/// `scheduledWorkouts` reads the session back, so the app cheerfully reports a workout sitting
/// on a watch that does not exist. `WCSession.isPaired` is the question actually worth asking.
///
/// No watch app target is needed: pairing is a property of the phone, not of a companion app.
@MainActor
final class WatchPairing: NSObject, WCSessionDelegate {
    static let shared = WatchPairing()

    enum State: Equatable {
        /// This device cannot pair a watch at all (iPad, or WatchConnectivity unavailable).
        case unsupported
        /// Supported, but the session has not finished activating yet.
        case unknown
        case noWatchPaired
        case paired
    }

    private(set) var state: State = .unknown

    private override init() {
        super.init()
    }

    /// Activates the session once and resolves the state. Safe to call repeatedly.
    func refresh() async -> State {
        guard WCSession.isSupported() else {
            state = .unsupported
            return state
        }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated {
            session.activate()
            // Activation is asynchronous and has no async form. One short wait is enough in
            // practice, and the state is re-read on the next refresh anyway rather than being
            // cached as a verdict.
            try? await Task.sleep(for: .milliseconds(400))
        }
        let resolvedState = resolved(session)
        #if DEBUG
        // Only on a change: this is the one line that explains "the app says it is on the watch
        // but nothing is there", so it is worth having, but not three times a screen.
        if resolvedState != state || !hasLogged {
            hasLogged = true
            print("[watch] isPaired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled) " +
                  "activation=\(session.activationState.rawValue) " +
                  "WorkoutScheduler.isSupported=\(WorkoutExport.isSupported) -> \(resolvedState)")
        }
        #endif
        state = resolvedState
        return state
    }

    #if DEBUG
    private var hasLogged = false
    #endif

    private func resolved(_ session: WCSession) -> State {
        guard session.activationState == .activated else { return .unknown }
        return session.isPaired ? .paired : .noWatchPaired
    }

    // MARK: WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.state = self.resolved(session)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.state = self.resolved(session)
        }
    }
}
