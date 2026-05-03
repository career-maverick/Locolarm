import AlarmKit
import AppIntents
import Foundation

/// Stops in-app arrival audio and clears ringing state when the user dismisses the system AlarmKit alert.
struct StopArrivalAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AlarmService.shared.dismissAlarm()
        }
        return .result()
    }
}

/// Runs ETA fallback evaluation when the user dismisses the ETA deadline AlarmKit alert.
struct EvaluateEtaFallbackAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Dismiss"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            LocationService.shared.handleEtaFallbackDeadlineNotificationEvent()
            AlarmService.shared.cancelEtaDeadlineAlarmKit()
        }
        return .result()
    }
}
