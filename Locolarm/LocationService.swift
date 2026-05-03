import CoreLocation
import Combine
import Foundation
import MapKit
import UserNotifications

/// Owns location permissions, geofence/live monitoring, distance updates, and ETA fallback scheduling.
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    /// App-friendly authorization states used by UI/view model.
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

    /// Wall-clock deadline when the route-based ETA timer reaches zero (updated when directions refresh).
    @Published private(set) var etaFallbackDeadline: Date?

    /// Called when geofence or distance confirms arrival (precise path).
    var onArrival: (() -> Void)?

    /// Called when the ETA dead-reckoning deadline fires under stale/unreliable GPS rules.
    var onEtaFallbackArrival: (() -> Void)?

    private let manager = CLLocationManager()
    private var activeDestination: Destination?
    private var usePowerSaverOnly = false
    private var etaFallbackEnabled = true
    private var hasTriggeredArrival = false
    private var routeDistanceTask: Task<Void, Never>?
    private var lastRouteOrigin: CLLocationCoordinate2D?
    private var lastRouteRequestDate: Date?
    private let routeRefreshInterval: TimeInterval = 20
    private let routeRecomputeMinMovementMeters: CLLocationDistance = 250
    private var etaEvaluationTimer: Timer?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        refreshAuthorizationState()
    }

    /// Requests Always authorization for background-capable monitoring.
    func requestPermissions() {
        manager.requestAlwaysAuthorization()
    }

    /// Requests a one-shot location fix when authorization allows it.
    func requestCurrentLocationFix() {
        guard authorizationState == .always || authorizationState == .whenInUse else { return }
        manager.requestLocation()
    }

    /// Arms geofence tracking and optional live updates for the destination.
    func arm(
        destination: Destination,
        usePowerSaverOnly: Bool,
        etaFallbackEnabled: Bool
    ) {
        if
            let activeDestination,
            activeDestination.id == destination.id,
            self.usePowerSaverOnly == usePowerSaverOnly,
            self.etaFallbackEnabled == etaFallbackEnabled
        {
            monitoringDescription = usePowerSaverOnly ? "Geofence only (unchanged)" : "Hybrid (unchanged)"
            restartEtaEvaluationTimerIfNeeded()
            return
        }

        disarm()

        activeDestination = destination
        self.usePowerSaverOnly = usePowerSaverOnly
        self.etaFallbackEnabled = etaFallbackEnabled
        hasTriggeredArrival = false
        etaFallbackDeadline = nil

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
            manager.startUpdatingLocation()
            manager.requestLocation()
        } else {
            manager.requestLocation()
        }

        monitoringDescription = usePowerSaverOnly ? "Geofence only" : "Hybrid (geofence + live updates)"
        restartEtaEvaluationTimerIfNeeded()
    }

    /// Clears all active region and location monitoring state.
    func disarm() {
        routeDistanceTask?.cancel()
        routeDistanceTask = nil
        lastRouteOrigin = nil
        lastRouteRequestDate = nil
        etaEvaluationTimer?.invalidate()
        etaEvaluationTimer = nil
        cancelEtaFallbackNotificationScheduling()
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        activeDestination = nil
        hasTriggeredArrival = false
        lastDistanceMeters = nil
        etaFallbackDeadline = nil
        monitoringDescription = "Not armed"
    }

    /// Invoked when the ETA deadline notification fires (foreground/background delivery path).
    func handleEtaFallbackDeadlineNotificationEvent() {
        evaluateEtaFallbackIfNeeded()
    }

    /// Maps CLLocationManager authorization into app-specific enum values.
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

    /// Processes latest location, updates distance, and triggers arrival checks.
    private func processLocation(_ location: CLLocation) {
        currentLocation = location
        guard let activeDestination, !hasTriggeredArrival else { return }
        let target = CLLocation(latitude: activeDestination.latitude, longitude: activeDestination.longitude)
        let straightLineDistance = location.distance(from: target)
        lastDistanceMeters = straightLineDistance
        requestRoadDistanceIfNeeded(
            from: location.coordinate,
            to: activeDestination.coordinate,
            fallbackDistanceMeters: straightLineDistance
        )
        if straightLineDistance <= activeDestination.radiusMeters {
            triggerArrivalIfNeeded()
        }
    }

    /// Requests Apple Maps route distance and ETA with throttling and fallback behavior.
    private func requestRoadDistanceIfNeeded(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        fallbackDistanceMeters: CLLocationDistance
    ) {
        if let lastRouteOrigin {
            let last = CLLocation(latitude: lastRouteOrigin.latitude, longitude: lastRouteOrigin.longitude)
            let current = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            let moved = current.distance(from: last)
            let isTooSoon = (lastRouteRequestDate?.timeIntervalSinceNow ?? -.infinity) > -routeRefreshInterval
            if moved < routeRecomputeMinMovementMeters && isTooSoon {
                return
            }
        }

        routeDistanceTask?.cancel()
        lastRouteOrigin = origin
        lastRouteRequestDate = Date()

        routeDistanceTask = Task { [weak self] in
            guard let self else { return }

            let request = MKDirections.Request()
            request.source = MKMapItem(
                location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                address: nil
            )
            request.destination = MKMapItem(
                location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
                address: nil
            )
            request.transportType = .automobile

            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled else { return }
                let route = response.routes.first
                await MainActor.run {
                    if let route {
                        self.lastDistanceMeters = route.distance
                        self.applyRouteETA(expectedTravelTime: route.expectedTravelTime)
                    } else {
                        self.lastDistanceMeters = fallbackDistanceMeters
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.lastDistanceMeters = fallbackDistanceMeters
                }
            }
        }
    }

    /// Updates ETA fallback deadline from Maps route remaining travel time and reschedules local notifications.
    private func applyRouteETA(expectedTravelTime: TimeInterval) {
        guard etaFallbackEnabled, activeDestination != nil, !hasTriggeredArrival else { return }
        let deadline = Date().addingTimeInterval(expectedTravelTime)
        etaFallbackDeadline = deadline
        rescheduleEtaFallbackDeadlineNotification(deadline: deadline)
    }

    private func rescheduleEtaFallbackDeadlineNotification(deadline: Date) {
        guard etaFallbackEnabled, activeDestination != nil else { return }
        cancelEtaFallbackNotificationScheduling()

        let interval = deadline.timeIntervalSinceNow
        if interval <= 1 {
            evaluateEtaFallbackIfNeeded()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Locolarm"
        content.body = "Your scheduled arrival time has passed. Open the app to hear the alarm if needed."
        content.interruptionLevel = .timeSensitive
        content.sound = nil

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: ETAFallbackConstants.deadlineNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)

        let destinationLabel = activeDestination?.name ?? "Destination"
        Task { @MainActor in
            await AlarmService.shared.scheduleEtaDeadlineAlarmKit(deadline: deadline, destinationLabel: destinationLabel)
        }
    }

    private func cancelEtaFallbackNotificationScheduling() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [ETAFallbackConstants.deadlineNotificationIdentifier]
        )
        AlarmService.shared.cancelEtaDeadlineAlarmKit()
    }

    private func restartEtaEvaluationTimerIfNeeded() {
        etaEvaluationTimer?.invalidate()
        etaEvaluationTimer = nil
        guard etaFallbackEnabled, activeDestination != nil else { return }

        etaEvaluationTimer = Timer.scheduledTimer(
            withTimeInterval: ETAFallbackConstants.foregroundEvaluationIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.evaluateEtaFallbackIfNeeded()
        }
        RunLoop.main.add(etaEvaluationTimer!, forMode: .common)
    }

    /// Evaluates whether the ETA fallback should fire (deadline reached, GPS stale or contradictions handled).
    func evaluateEtaFallbackIfNeeded() {
        guard etaFallbackEnabled else { return }
        guard let destination = activeDestination, !hasTriggeredArrival else { return }
        guard let deadline = etaFallbackDeadline, Date() >= deadline else { return }

        let target = CLLocation(latitude: destination.latitude, longitude: destination.longitude)

        if let loc = currentLocation {
            let age = abs(loc.timestamp.timeIntervalSinceNow)
            let accurate = loc.horizontalAccuracy > 0
                && loc.horizontalAccuracy <= ETAFallbackConstants.maxHorizontalAccuracyMetersForFreshFix
            let fresh = age < ETAFallbackConstants.locationStaleThresholdSeconds

            if fresh && accurate {
                let dist = loc.distance(from: target)
                if dist <= destination.radiusMeters {
                    triggerArrivalIfNeeded()
                    return
                }
                let suppressBeyond = ETAFallbackConstants.minimumSuppressDistanceMeters(arrivalRadiusMeters: destination.radiusMeters)
                if dist > suppressBeyond {
                    monitoringDescription = "ETA fallback skipped — recent GPS suggests you are still far away."
                    return
                }
            }
        }

        triggerEtaFallbackArrivalIfNeeded()
    }

    /// Invokes precise arrival callback once per armed session.
    private func triggerArrivalIfNeeded() {
        guard !hasTriggeredArrival else { return }
        hasTriggeredArrival = true
        cancelEtaFallbackNotificationScheduling()
        etaEvaluationTimer?.invalidate()
        etaEvaluationTimer = nil
        etaFallbackDeadline = nil
        onArrival?()
    }

    private func triggerEtaFallbackArrivalIfNeeded() {
        guard !hasTriggeredArrival else { return }
        hasTriggeredArrival = true
        cancelEtaFallbackNotificationScheduling()
        etaEvaluationTimer?.invalidate()
        etaEvaluationTimer = nil
        etaFallbackDeadline = nil
        onEtaFallbackArrival?()
    }
}

extension LocationService: CLLocationManagerDelegate {
    /// Handles runtime authorization changes.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorizationState()
        requestCurrentLocationFix()
    }

    /// Receives location updates from Core Location.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        processLocation(location)
    }

    /// Receives Core Location errors from one-shot/following requests.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        monitoringDescription = "Location error: \(error.localizedDescription)"
    }

    /// Triggers arrival when entering the monitored destination region.
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        triggerArrivalIfNeeded()
    }

    /// Handles initial region-state callback after monitoring begins.
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside {
            triggerArrivalIfNeeded()
        }
    }

    /// Handles region monitoring failures.
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        monitoringDescription = "Monitoring failed: \(error.localizedDescription)"
    }
}
