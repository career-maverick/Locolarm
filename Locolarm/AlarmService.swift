import AVFAudio
import AudioToolbox
import Combine
import Foundation
import UserNotifications

final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    enum ToneID: String, CaseIterable {
        case systemDefault
        case toneBeacon
        case tonePulse
        case toneEcho

        var displayName: String {
            switch self {
            case .systemDefault: return "System Default"
            case .toneBeacon: return "Beacon"
            case .tonePulse: return "Pulse"
            case .toneEcho: return "Echo"
            }
        }

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

        var fallbackSystemSoundID: SystemSoundID {
            switch self {
            case .systemDefault: return 1007
            case .toneBeacon: return 1005
            case .tonePulse: return 1008
            case .toneEcho: return 1054
            }
        }
    }

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

    func requestNotificationPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func triggerArrivalAlarm(destinationName: String) {
        state = .ringing
        startBeepingLoop()
        scheduleArrivalNotification(destinationName: destinationName)
    }

    func setTone(_ tone: ToneID) {
        selectedTone = tone
    }

    func dismissAlarm() {
        stopBeepingLoop()
        state = .idle
    }

    func snooze(minutes: Int = 5) {
        stopBeepingLoop()
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        state = .snoozed(until: until)
    }

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

    private func stopBeepingLoop() {
        beepTimer?.invalidate()
        beepTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

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

    private func notificationSound(for tone: ToneID) -> UNNotificationSound {
        guard let filename = tone.bundledFilename else { return .default }
        guard Bundle.main.url(forResource: filename, withExtension: nil) != nil else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
    }
}
