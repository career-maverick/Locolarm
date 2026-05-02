import CoreLocation
import Foundation

extension Notification.Name {
    /// Posted when the ETA deadline local notification fires so the app can evaluate fallback arrival.
    static let locolarmEtaFallbackDeadline = Notification.Name("locolarmEtaFallbackDeadline")
}

/// Tunable thresholds for ETA-based dead reckoning when GPS is stale or unreliable.
enum ETAFallbackConstants {
    /// Location fixes older than this are treated as stale for fallback decisions.
    static let locationStaleThresholdSeconds: TimeInterval = 45

    /// Horizontal accuracy at or below this (meters) counts as a usable fix when recent.
    static let maxHorizontalAccuracyMetersForFreshFix: CLLocationAccuracy = 280

    /// Minimum factor beyond arrival radius before we suppress fallback when GPS looks fresh.
    static func minimumSuppressDistanceMeters(arrivalRadiusMeters: Double) -> CLLocationDistance {
        max(arrivalRadiusMeters * 2.5, 800)
    }

    /// Fixed notification identifier for rescheduling / cancellation.
    static let deadlineNotificationIdentifier = "locolarm-eta-fallback-deadline"

    /// Foreground evaluation timer interval when armed with ETA fallback enabled.
    static let foregroundEvaluationIntervalSeconds: TimeInterval = 12
}
