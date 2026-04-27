import AVFAudio
import AudioToolbox
import Combine
import Foundation
import UserNotifications

/// Handles alarm sound playback, snooze lifecycle, and arrival notifications.
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    /// Selectable alarm tone identifiers exposed in settings.
    enum ToneID: String, CaseIterable {
        case systemDefault
        case toneBeacon
        case tonePulse
        case toneEcho

        /// User-facing tone name.
        var displayName: String {
            switch self {
            case .systemDefault: return "System Default"
            case .toneBeacon: return "Beacon"
            case .tonePulse: return "Pulse"
            case .toneEcho: return "Echo"
            }
        }

        /// Optional bundled audio filename for looped playback.
        var bundledFilename: String? {
            switch self {
            case .systemDefault:
                return nil
            case .toneBeacon:
                return "tone-beacon.caf"
            case .tonePulse:
                return "tone-pulse.caf"
            case .toneEcho:
                return "tone-echo.caf"
            }
        }

        /// Fallback system sound used when bundled file is unavailable.
        var fallbackSystemSoundID: SystemSoundID {
            switch self {
            case .systemDefault: return 1007
            case .toneBeacon: return 1005
            case .tonePulse: return 1008
            case .toneEcho: return 1054
            }
        }
    }

    /// Public alarm state consumed by UI.
    enum State: Equatable {
        case idle
        case ringing
        case snoozed(until: Date)
    }

    @Published private(set) var state: State = .idle

    private var beepTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private let center = UNUserNotificationCenter.current()
    private var selectedTone: ToneID = .systemDefault

    private init() {}

    /// Requests notification permission needed for arrival alerts.
    func requestNotificationPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Starts ringing flow when the user is detected at destination.
    func triggerArrivalAlarm(destinationName: String) {
        state = .ringing
        startBeepingLoop()
        scheduleArrivalNotification(destinationName: destinationName)
    }

    /// Updates the active tone selection.
    func setTone(_ tone: ToneID) {
        selectedTone = tone
    }

    /// Stops ringing and returns service to idle.
    func dismissAlarm() {
        stopBeepingLoop()
        state = .idle
    }

    /// Silences current alarm and marks snooze-until timestamp.
    func snooze(minutes: Int = 5) {
        stopBeepingLoop()
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        state = .snoozed(until: until)
    }

    /// Starts a repeating alarm sound loop via bundled audio or system sounds.
    private func startBeepingLoop() {
        stopBeepingLoop()

        if startBundledLoopPlaybackIfPossible() {
            return
        }

        AudioServicesPlaySystemSound(selectedTone.fallbackSystemSoundID)
        beepTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            AudioServicesPlaySystemSound(self.selectedTone.fallbackSystemSoundID)
        }
    }

    /// Stops any repeating audio resources used by the alarm.
    private func stopBeepingLoop() {
        beepTimer?.invalidate()
        beepTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Schedules a local notification to surface arrival even in background.
    private func scheduleArrivalNotification(destinationName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locolarm"
        content.body = "You reached \(destinationName). Alarm is active."
        content.sound = notificationSound(for: selectedTone)
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "arrival-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Attempts continuous playback using a bundled tone file.
    private func startBundledLoopPlaybackIfPossible() -> Bool {
        guard let filename = selectedTone.bundledFilename else { return false }
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            return true
        } catch {
            audioPlayer = nil
            return false
        }
    }

    /// Resolves the notification sound for the currently selected tone.
    private func notificationSound(for tone: ToneID) -> UNNotificationSound {
        guard let filename = tone.bundledFilename else { return .default }
        guard Bundle.main.url(forResource: filename, withExtension: nil) != nil else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
    }
}
