import Foundation
import Observation

/// Whether a rider is signed in, for the views (RULE-37 in milestone 10's rules.md). Fed by
/// `AuthSession`'s events; `SessionGate` decides when the sign-in flow may replace the app.
@MainActor
@Observable
final class SessionState {
    enum Status: Equatable {
        case signedOut
        case signedIn(riderId: String)
        /// Involuntarily: the refresh was refused or a refreshed request still got 401.
        case ended(SessionEndReason)
    }

    private(set) var status: Status
    private var observation: Task<Void, Never>?

    init(status: Status) {
        self.status = status
    }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    /// The message to show on the sign-in form after the session ended, if any (AC-121).
    var endedMessage: String? {
        if case let .ended(.disabled(message)) = status { return message }
        if case .ended(.expired) = status { return "Your session has ended. Please sign in again." }
        return nil
    }

    /// Follows `events` for as long as this object lives.
    func observe(_ events: AsyncStream<AuthSession.Event>) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
    }

    func apply(_ event: AuthSession.Event) {
        switch event {
        case let .signedIn(riderId): status = .signedIn(riderId: riderId)
        case let .ended(reason): status = .ended(reason)
        }
    }

    /// After a deliberate sign-out or account deletion.
    func signedOut() {
        status = .signedOut
    }
}

/// RULE-37, RA-23: when the sign-in flow replaces the app. Never while a ride is preparing, being
/// resumed, active, finishing or still on screen (its summary included): an ended session must not
/// interrupt a ride, so the sign-in form waits until the rider is back home.
enum SessionGate {
    static func showsSignIn(status: SessionState.Status, ridePhase: RideCoordinator.Phase, rideOnScreen: Bool) -> Bool {
        if case .signedIn = status { return false }
        return ridePhase == .idle && !rideOnScreen
    }
}
