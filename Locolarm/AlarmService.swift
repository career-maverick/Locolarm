import AVFAudio
import AudioToolbox
import Combine
import Foundation
import MediaPlayer
import UserNotifications

/// Handles alarm sound playback with background-capable audio session, lock-screen controls, and recovery after interruptions.
///
/// Requires **Audio, AirPlay, and Picture in Picture** (`audio`) in `UIBackgroundModes` so looping playback continues when the app is not in the foreground.
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    /// Distinguishes precise GPS/geofence arrival from ETA route-timer fallback (dead reckoning).
    enum ArrivalTriggerReason: Equatable {
        case gpsConfirmed
        case etaFallbackRouteTimer
    }

    /// Selectable alarm tone identifiers exposed in settings. Each maps to a bundled loop file for reliable background playback.
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

        /// Bundled audio filename (WAV) used for continuous looping and notification sounds.
        var bundledFilename: String {
            switch self {
            case .systemDefault: return "alarm-default.wav"
            case .toneBeacon: return "tone-beacon.wav"
            case .tonePulse: return "tone-pulse.wav"
            case .toneEcho: return "tone-echo.wav"
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
        case ringing(ArrivalTriggerReason)
        case snoozed(until: Date)
    }

    @Published private(set) var state: State = .idle

    private var beepTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private let notificationCenter = UNUserNotificationCenter.current()
    private var selectedTone: ToneID = .systemDefault
    private var lastAlarmDestinationName: String?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private init() {
        installAudioSessionObservers()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func requestNotificationPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func triggerArrivalAlarm(destinationName: String, reason: ArrivalTriggerReason = .gpsConfirmed) {
        lastAlarmDestinationName = destinationName
        state = .ringing(reason)
        startAlarmSoundLoop(destinationName: destinationName)
        scheduleArrivalNotification(destinationName: destinationName, reason: reason)
    }

    func setTone(_ tone: ToneID) {
        selectedTone = tone
    }

    func dismissAlarm() {
        stopAlarmSoundLoopTeardownSession()
        teardownRemoteTransportAndNowPlaying()
        state = .idle
        lastAlarmDestinationName = nil
    }

    func snooze(minutes: Int = 5) {
        stopAlarmSoundLoopTeardownSession()
        teardownRemoteTransportAndNowPlaying()
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        state = .snoozed(until: until)
        lastAlarmDestinationName = nil
    }

    /// Call when returning to foreground or after audio route/session changes so the alarm keeps looping like a system alarm.
    func recoverActiveAlarmPlaybackIfNeeded() {
        guard case .ringing = state else { return }
        do {
            try configureAlarmAudioSession()
            if let player = audioPlayer {
                if !player.isPlaying {
                    player.prepareToPlay()
                    player.play()
                }
            } else if let name = lastAlarmDestinationName {
                startAlarmSoundLoop(destinationName: name, isRecovery: true)
            }
        } catch {
            if let name = lastAlarmDestinationName {
                startAlarmSoundLoop(destinationName: name, isRecovery: true)
            }
        }
    }

    static func etaFallbackWarningBannerText(destinationName: String) -> String {
        "Approximate alert for \(destinationName): based on your last Apple Maps ETA before GPS became unavailable or unreliable. Confirm you are actually near your stop."
    }

    // MARK: - Audio session

    private func configureAlarmAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try session.setActive(true)
    }

    private func installAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            break
        case .ended:
            guard
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), case .ringing = state {
                try? configureAlarmAudioSession()
                audioPlayer?.play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable, case .ringing = state {
            try? configureAlarmAudioSession()
            if audioPlayer?.play() == false {
                recoverActiveAlarmPlaybackIfNeeded()
            }
        }
    }

    // MARK: - Playback

    private func startAlarmSoundLoop(destinationName: String, isRecovery: Bool = false) {
        if !isRecovery {
            teardownRemoteTransportAndNowPlaying()
        }

        do {
            try configureAlarmAudioSession()
        } catch {
            startLegacyTimerOnlyLoop()
            return
        }

        guard let url = resolveBundledAlarmSoundURL() else {
            startLegacyTimerOnlyLoop()
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            guard player.play() else {
                startLegacyTimerOnlyLoop()
                return
            }
            audioPlayer = player
            beepTimer?.invalidate()
            beepTimer = nil

            if case .ringing(let reason) = state {
                setupNowPlayingAndRemoteControls(destinationName: destinationName, reason: reason)
            }
        } catch {
            audioPlayer = nil
            startLegacyTimerOnlyLoop()
        }
    }

    private func resolveBundledAlarmSoundURL() -> URL? {
        let name = selectedTone.bundledFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext) {
            return url
        }
        return Bundle.main.url(forResource: "alarm-default", withExtension: "wav")
    }

    /// Last-resort path when bundled files are missing (should not occur in release builds with assets).
    private func startLegacyTimerOnlyLoop() {
        beepTimer?.invalidate()
        AudioServicesPlaySystemSound(selectedTone.fallbackSystemSoundID)
        let timer = Timer(fire: Date(), interval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            AudioServicesPlaySystemSound(self.selectedTone.fallbackSystemSoundID)
        }
        RunLoop.main.add(timer, forMode: .common)
        beepTimer = timer
    }

    private func stopAlarmSoundLoopTeardownSession() {
        beepTimer?.invalidate()
        beepTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Now Playing & lock screen

    private func setupNowPlayingAndRemoteControls(destinationName: String, reason: ArrivalTriggerReason) {
        let remote = MPRemoteCommandCenter.shared()
        remote.pauseCommand.removeTarget(nil)
        remote.stopCommand.removeTarget(nil)

        let title = reason == .etaFallbackRouteTimer
            ? "Locolarm — approximate arrival"
            : "Locolarm — arrival alarm"
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: destinationName,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPMediaItemPropertyPlaybackDuration: 86_400.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        remote.playCommand.isEnabled = false
        remote.pauseCommand.isEnabled = true
        remote.stopCommand.isEnabled = true
        remote.pauseCommand.addTarget { [weak self] _ in
            self?.userStoppedFromLockScreen()
            return .success
        }
        remote.stopCommand.addTarget { [weak self] _ in
            self?.userStoppedFromLockScreen()
            return .success
        }
    }

    private func teardownRemoteTransportAndNowPlaying() {
        let remote = MPRemoteCommandCenter.shared()
        remote.pauseCommand.removeTarget(nil)
        remote.stopCommand.removeTarget(nil)
        remote.pauseCommand.isEnabled = false
        remote.stopCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func userStoppedFromLockScreen() {
        dismissAlarm()
    }

    // MARK: - Notifications

    private func scheduleArrivalNotification(destinationName: String, reason: ArrivalTriggerReason) {
        let content = UNMutableNotificationContent()
        content.title = "Locolarm"
        switch reason {
        case .gpsConfirmed:
            content.body = "You reached \(destinationName). Alarm is active."
        case .etaFallbackRouteTimer:
            content.body =
                "Approximate arrival for \(destinationName): timer from your last Maps ETA ran out while GPS was inactive or unreliable. Confirm your location."
        }
        content.sound = notificationSound(for: selectedTone)
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "arrival-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func notificationSound(for tone: ToneID) -> UNNotificationSound {
        let filename = tone.bundledFilename
        guard Bundle.main.url(forResource: (filename as NSString).deletingPathExtension, withExtension: (filename as NSString).pathExtension) != nil
        else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
    }
}
