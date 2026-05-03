import ActivityKit
import AlarmKit
import AudioToolbox
import AVFAudio
import Combine
import Foundation
import MediaPlayer
import SwiftUI
import UserNotifications

/// Handles alarm sound playback with background-capable audio session, lock-screen controls, and recovery after interruptions.
///
/// Requires **Audio, AirPlay, and Picture in Picture** (`audio`) in `UIBackgroundModes` so looping playback continues when the app is not in the foreground.
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    /// Stable AlarmKit identifier for immediate arrival alerts (rescheduled on each trigger).
    static let arrivalAlarmKitID = UUID(uuidString: "B1111111-1111-4111-8111-111111111111")!

    /// Stable AlarmKit identifier for the ETA fallback deadline alarm.
    static let etaDeadlineAlarmKitID = UUID(uuidString: "C2222222-2222-4222-8222-222222222222")!

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

    /// Mirrors `AlarmManager.shared.authorizationState` for settings UI.
    @Published private(set) var alarmKitAuthorization: AlarmManager.AuthorizationState = .notDetermined

    private var beepTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private let notificationCenter = UNUserNotificationCenter.current()
    private var selectedTone: ToneID = .systemDefault
    private var lastAlarmDestinationName: String?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private init() {
        alarmKitAuthorization = AlarmManager.shared.authorizationState
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

    func refreshAlarmKitAuthorizationFromSystem() {
        alarmKitAuthorization = AlarmManager.shared.authorizationState
    }

    /// Prompts for AlarmKit access when still undetermined (typically when arming).
    func requestAlarmKitAuthorizationIfNeeded() async {
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        await MainActor.run {
            refreshAlarmKitAuthorizationFromSystem()
        }
    }

    func triggerArrivalAlarm(destinationName: String, reason: ArrivalTriggerReason = .gpsConfirmed) {
        lastAlarmDestinationName = destinationName
        state = .ringing(reason)
        startAlarmSoundLoop(destinationName: destinationName)
        scheduleArrivalNotification(destinationName: destinationName, reason: reason)
        Task { @MainActor in
            await scheduleArrivalAlarmKit(destinationName: destinationName, reason: reason)
        }
    }

    func setTone(_ tone: ToneID) {
        selectedTone = tone
    }

    func dismissAlarm() {
        cancelArrivalAlarmKitIfNeeded()
        stopAlarmSoundLoopTeardownSession()
        teardownRemoteTransportAndNowPlaying()
        state = .idle
        lastAlarmDestinationName = nil
    }

    func snooze(minutes: Int = 5) {
        cancelArrivalAlarmKitIfNeeded()
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
            startFallbackPlaybackRetryLoop(destinationName: destinationName)
            return
        }

        guard let url = resolveBundledAlarmSoundURL() else {
            startFallbackPlaybackRetryLoop(destinationName: destinationName)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            guard player.play() else {
                startFallbackPlaybackRetryLoop(destinationName: destinationName)
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
            startFallbackPlaybackRetryLoop(destinationName: destinationName)
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

    /// Retries bundled `AVAudioPlayer` playback on a timer — avoids `AudioServicesPlaySystemSound`, which honors the silent switch.
    private func startFallbackPlaybackRetryLoop(destinationName: String) {
        beepTimer?.invalidate()
        var attempts = 0
        let timer = Timer(fire: Date(), interval: 0.7, repeats: true) { [weak self] timerRef in
            guard let self else {
                timerRef.invalidate()
                return
            }
            attempts += 1
            if attempts > 60 || !self.checkRingingForFallbackTimer() {
                timerRef.invalidate()
                self.beepTimer = nil
                return
            }
            self.attemptBundledPlaybackRecovery(destinationName: destinationName)
            if self.audioPlayer?.isPlaying == true {
                timerRef.invalidate()
                self.beepTimer = nil
            }
        }
        beepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkRingingForFallbackTimer() -> Bool {
        if case .ringing = state { return true }
        return false
    }

    private func attemptBundledPlaybackRecovery(destinationName: String) {
        guard let url = resolveBundledAlarmSoundURL() else { return }
        do {
            try configureAlarmAudioSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            guard player.play() else { return }
            audioPlayer = player
            if case .ringing(let reason) = state {
                setupNowPlayingAndRemoteControls(destinationName: destinationName, reason: reason)
            }
        } catch {}
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

    // MARK: - AlarmKit

    private func cancelArrivalAlarmKitIfNeeded() {
        try? AlarmManager.shared.cancel(id: Self.arrivalAlarmKitID)
    }

    func cancelEtaDeadlineAlarmKit() {
        try? AlarmManager.shared.cancel(id: Self.etaDeadlineAlarmKitID)
    }

    /// System ETA deadline alert (breaks through Silent / Focus when authorized).
    @MainActor
    func scheduleEtaDeadlineAlarmKit(deadline: Date, destinationLabel: String) async {
        guard AlarmManager.shared.authorizationState == .authorized else { return }
        guard deadline.timeIntervalSinceNow > 2 else { return }

        let title = LocalizedStringResource(stringLiteral: "Locolarm — ETA timer (\(destinationLabel))")
        let alert = AlarmPresentation.Alert(title: title)
        let attrs = AlarmAttributes<LocolarmAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: nil,
            tintColor: .orange
        )
        let sound = Self.alertSound(for: selectedTone)
        let config = AlarmManager.AlarmConfiguration<LocolarmAlarmMetadata>.alarm(
            schedule: .fixed(deadline),
            attributes: attrs,
            stopIntent: EvaluateEtaFallbackAlarmIntent(),
            sound: sound
        )
        try? AlarmManager.shared.cancel(id: Self.etaDeadlineAlarmKitID)
        _ = try? await AlarmManager.shared.schedule(id: Self.etaDeadlineAlarmKitID, configuration: config)
    }

    @MainActor
    private func scheduleArrivalAlarmKit(destinationName: String, reason: ArrivalTriggerReason) async {
        guard AlarmManager.shared.authorizationState == .authorized else { return }

        let titleText: String
        switch reason {
        case .gpsConfirmed:
            titleText = "Arrived near \(destinationName)"
        case .etaFallbackRouteTimer:
            titleText = "Approximate arrival — \(destinationName)"
        }
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: titleText))
        let attrs = AlarmAttributes<LocolarmAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: nil,
            tintColor: .orange
        )
        let sound = Self.alertSound(for: selectedTone)
        let fireDate = Date().addingTimeInterval(1.5)
        let config = AlarmManager.AlarmConfiguration<LocolarmAlarmMetadata>.alarm(
            schedule: .fixed(fireDate),
            attributes: attrs,
            stopIntent: StopArrivalAlarmIntent(),
            sound: sound
        )
        try? AlarmManager.shared.cancel(id: Self.arrivalAlarmKitID)
        _ = try? await AlarmManager.shared.schedule(id: Self.arrivalAlarmKitID, configuration: config)
    }

    private static func alertSound(for tone: ToneID) -> AlertConfiguration.AlertSound {
        let base = (tone.bundledFilename as NSString).deletingPathExtension
        if Bundle.main.url(forResource: base, withExtension: "wav") != nil {
            return .named(base)
        }
        return .default
    }
}
