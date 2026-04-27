import CoreLocation
import Combine
import Foundation

final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    enum AuthorizationState: Equatable {
        case notDetermined
        case denied
        case whenInUse
        case always
    }

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var lastDistanceMeters: Double?
    @Published private(set) var monitoringDescription = "Not armed"

    var onArrival: (() -> Void)?

    private let manager = CLLocationManager()
    private var activeDestination: Destination?
    private var usePowerSaverOnly = false
    private var hasTriggeredArrival = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        refreshAuthorizationState()
    }

    func requestPermissions() {
        manager.requestAlwaysAuthorization()
    }

    func requestCurrentLocationFix() {
        guard authorizationState == .always || authorizationState == .whenInUse else { return }
        manager.requestLocation()
    }

    func arm(
        destination: Destination,
        usePowerSaverOnly: Bool
    ) {
        if
            let activeDestination,
            activeDestination.id == destination.id,
            self.usePowerSaverOnly == usePowerSaverOnly
        {
            monitoringDescription = usePowerSaverOnly ? "Geofence only (unchanged)" : "Hybrid (unchanged)"
            return
        }

        disarm()

        activeDestination = destination
        self.usePowerSaverOnly = usePowerSaverOnly
        hasTriggeredArrival = false

        let region = CLCircularRegion(
            center: destination.coordinate,
            radius: max(50, min(destination.radiusMeters, manager.maximumRegionMonitoringDistance)),
            identifier: destination.id.uuidString
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        manager.startMonitoring(for: region)

        if !usePowerSaverOnly {
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        }

        monitoringDescription = usePowerSaverOnly ? "Geofence only" : "Hybrid (geofence + live updates)"
    }

    func disarm() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        activeDestination = nil
        hasTriggeredArrival = false
        lastDistanceMeters = nil
        monitoringDescription = "Not armed"
    }

    private func refreshAuthorizationState() {
        switch manager.authorizationStatus {
        case .notDetermined:
            authorizationState = .notDetermined
        case .restricted, .denied:
            authorizationState = .denied
        case .authorizedWhenInUse:
            authorizationState = .whenInUse
        case .authorizedAlways:
            authorizationState = .always
        @unknown default:
            authorizationState = .denied
        }
    }

    private func processLocation(_ location: CLLocation) {
        currentLocation = location
        guard let activeDestination, !hasTriggeredArrival else { return }
        let target = CLLocation(latitude: activeDestination.latitude, longitude: activeDestination.longitude)
        let distance = location.distance(from: target)
        lastDistanceMeters = distance
        if distance <= activeDestination.radiusMeters {
            triggerArrivalIfNeeded()
        }
    }

    private func triggerArrivalIfNeeded() {
        guard !hasTriggeredArrival else { return }
        hasTriggeredArrival = true
        onArrival?()
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorizationState()
        requestCurrentLocationFix()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        processLocation(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // requestLocation requires this delegate callback to exist.
        monitoringDescription = "Location error: \(error.localizedDescription)"
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        triggerArrivalIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside {
            triggerArrivalIfNeeded()
        }
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        monitoringDescription = "Monitoring failed: \(error.localizedDescription)"
    }
}
