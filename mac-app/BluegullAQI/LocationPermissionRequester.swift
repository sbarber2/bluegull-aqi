import CoreLocation
import Observation

/// Requests and observes CoreLocation authorization for current-location
/// mode (bluegull-aqi-e70.2). `LocationResolver`/`SystemLocationProvider`
/// deliberately never do this themselves -- see their own doc comments --
/// so this is the app-level piece that actually triggers the system
/// permission dialog.
@Observable
final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager

    private(set) var authorizationStatus: CLAuthorizationStatus

    /// `requestOnInit` defaults to `false` so constructing this type (e.g.
    /// in a preview or a future test) never has the side effect of
    /// triggering a system dialog just by existing -- callers that want
    /// that (the real app, on launch) opt in explicitly.
    init(manager: CLLocationManager = CLLocationManager(), requestOnInit: Bool = false) {
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        if requestOnInit {
            requestAuthorizationIfNeeded()
        }
    }

    /// Triggers the system permission dialog only if status is genuinely
    /// undecided. A no-op otherwise -- CoreLocation itself refuses to
    /// re-prompt once the user has answered, so there's no reason for this
    /// to attempt it; a denied/restricted status needs the user to change
    /// it in System Settings, not another `requestWhenInUseAuthorization()`
    /// call.
    func requestAuthorizationIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}
