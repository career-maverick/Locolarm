import CoreLocation
import Foundation
import MapKit
import Combine

@MainActor
final class AlarmViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    enum QuickPlaceSelectionResult: Equatable {
        case used
        case needsHomeSetup
        case needsWorkSetup
        case noAction
    }

    enum PendingQuickPlaceSave: Equatable {
        case home
        case work

        var displayName: String {
            switch self {
            case .home: return "Home"
            case .work: return "Work"
            }
        }
    }

    enum QuickPlace: String, CaseIterable, Identifiable {
        case home
        case work
        case recentCustom
        case add

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .work: return "Work"
            case .recentCustom: return "Recent"
            case .add: return "+"
            }
        }
    }

    enum DistanceUnitSystem: String, CaseIterable, Identifiable {
        case metric
        case imperial

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .metric: return "Kilometers"
            case .imperial: return "Miles"
            }
        }
    }

    @Published var query = "" {
        didSet { scheduleAutocomplete() }
    }
    @Published var completionResults: [MKLocalSearchCompletion] = []
    @Published var selectedDestination: Destination?
    @Published var isDestinationConfirmed = false
    @Published var homePlace: Destination = .savedHome
    @Published var workPlace: Destination = .savedWork
    @Published var customPlaces: [CustomPlace] = []
    @Published var radiusMeters: Double = 200
    @Published var userPowerSaverMode = false
    @Published var distanceUnitSystem: DistanceUnitSystem = .metric
    @Published var selectedToneID: AlarmService.ToneID = .systemDefault
    @Published var isArmed = false
    @Published var statusText = "Pick a destination to start."
    @Published var isSearching = false
    @Published private(set) var pendingQuickPlaceSave: PendingQuickPlaceSave?

    @Published private(set) var alarmState: AlarmService.State = .idle
    @Published private(set) var lowPowerModeActive = false
    @Published private(set) var locationAuthorization: LocationService.AuthorizationState = .notDetermined
    @Published private(set) var distanceRemaining: Double?
    @Published private(set) var currentLocationCoordinate: CLLocationCoordinate2D?

    var effectivePowerSaverMode: Bool {
        userPowerSaverMode || lowPowerModeActive
    }

    private let locationService: LocationService
    private let alarmService: AlarmService
    private let powerModeService: PowerModeService

    private let activeAlarmKey = "active-alarm-destination"
    private let homePlaceKey = "saved-home-place"
    private let workPlaceKey = "saved-work-place"
    private let customPlacesKey = "saved-custom-places"
    private let settingsDistanceUnitKey = "settings-distance-unit"
    private let settingsToneIDKey = "settings-tone-id"
    private var observerTask: Task<Void, Never>?
    private var snoozeTask: Task<Void, Never>?
    private var autocompleteTask: Task<Void, Never>?
    private var lastAppliedPowerSaverMode = false
    private let completer = MKLocalSearchCompleter()

    override init() {
        self.locationService = .shared
        self.alarmService = .shared
        self.powerModeService = .init()
        super.init()

        completer.delegate = self
        completer.resultTypes = .address

        locationService.onArrival = { [weak self] in
            self?.handleArrival()
        }

        restorePlaces()
        restoreSettings()
        restoreActiveAlarm()
        locationService.requestPermissions()
        locationService.requestCurrentLocationFix()
        alarmService.requestNotificationPermission()
        alarmService.setTone(selectedToneID)
        bindObservers()
    }

    deinit {
        observerTask?.cancel()
        snoozeTask?.cancel()
        autocompleteTask?.cancel()
    }

    func resolveCompletion(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let first = response.mapItems.first {
                return first
            }
            let fallbackRequest = MKLocalSearch.Request()
            fallbackRequest.naturalLanguageQuery = "\(completion.title) \(completion.subtitle)".trimmingCharacters(in: .whitespaces)
            fallbackRequest.resultTypes = [.address, .pointOfInterest]
            let fallbackResponse = try await MKLocalSearch(request: fallbackRequest).start()
            return fallbackResponse.mapItems.first
        } catch {
            statusText = "Search failed: \(error.localizedDescription)"
            return nil
        }
    }

    func useSearchResult(_ item: MKMapItem) {
        let destination = Destination(
            name: item.name ?? "Pinned Destination",
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            radiusMeters: radiusMeters
        )
        selectedDestination = destination
        isDestinationConfirmed = false
        statusText = "Selected \(destination.name)"
        query = item.name ?? item.placemark.title ?? destination.name
        completionResults = []
    }

    func usePinnedCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let destination = Destination(
            name: "Pinned Destination",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters
        )
        selectedDestination = destination
        isDestinationConfirmed = false
        statusText = "Pinned destination selected."
    }

    func confirmDestination() {
        guard let selectedDestination else {
            statusText = "Select a destination first."
            return
        }
        isDestinationConfirmed = true
        statusText = "Destination locked: \(selectedDestination.name)"
    }

    func armAlarm() {
        guard var destination = selectedDestination else {
            statusText = "Select a destination first."
            return
        }
        guard isDestinationConfirmed else {
            statusText = "Confirm the destination before turning alarm on."
            return
        }
        destination.radiusMeters = radiusMeters
        selectedDestination = destination

        locationService.arm(
            destination: destination,
            usePowerSaverOnly: effectivePowerSaverMode
        )
        lastAppliedPowerSaverMode = effectivePowerSaverMode
        isArmed = true
        statusText = "Alarm armed for \(destination.name)."
        persistActiveAlarm(destination)
    }

    func disarmAlarm() {
        locationService.disarm()
        alarmService.dismissAlarm()
        lastAppliedPowerSaverMode = false
        isArmed = false
        statusText = "Alarm disarmed."
        clearActiveAlarm()
    }

    func useSavedPlace(_ place: Destination) {
        selectedDestination = place
        isDestinationConfirmed = false
        radiusMeters = place.radiusMeters
        pendingQuickPlaceSave = nil
        statusText = "Selected saved place: \(place.name)"
    }

    func snoozeAlarm(minutes: Int = 5) {
        alarmService.snooze(minutes: minutes)
        statusText = "Snoozed for \(minutes) minutes."
        snoozeTask?.cancel()
        snoozeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            self.rearmAfterSnooze()
        }
    }

    func dismissAlarm() {
        alarmService.dismissAlarm()
        disarmAlarm()
    }

    private func handleArrival() {
        guard let destination = selectedDestination else { return }
        alarmService.triggerArrivalAlarm(destinationName: destination.name)
        statusText = "Arrived near \(destination.name). Alarm started."
    }

    private func rearmAfterSnooze() {
        guard let destination = selectedDestination else { return }
        locationService.arm(destination: destination, usePowerSaverOnly: effectivePowerSaverMode)
        lastAppliedPowerSaverMode = effectivePowerSaverMode
        isArmed = true
        statusText = "Snooze ended. Alarm re-armed."
    }

    private func bindObservers() {
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await lowPower in powerModeService.$isLowPowerModeEnabled.values {
                self.lowPowerModeActive = lowPower
                let nextMode = self.effectivePowerSaverMode
                if
                    self.isArmed,
                    nextMode != self.lastAppliedPowerSaverMode,
                    let destination = self.selectedDestination
                {
                    self.locationService.arm(destination: destination, usePowerSaverOnly: self.effectivePowerSaverMode)
                    self.lastAppliedPowerSaverMode = nextMode
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in locationService.$authorizationState.values {
                self.locationAuthorization = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in locationService.$lastDistanceMeters.values {
                self.distanceRemaining = value
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in locationService.$currentLocation.values {
                self.currentLocationCoordinate = value?.coordinate
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for await value in alarmService.$state.values {
                self.alarmState = value
            }
        }
    }

    func completionTitle(_ completion: MKLocalSearchCompletion) -> String {
        completion.title.isEmpty ? completion.subtitle : completion.title
    }

    func completionSubtitle(_ completion: MKLocalSearchCompletion) -> String {
        completion.title.isEmpty ? "" : completion.subtitle
    }

    var radiusDisplayText: String {
        formatDistance(meters: radiusMeters)
    }

    var distanceRemainingDisplayText: String? {
        guard let distanceRemaining else { return nil }
        return formatDistance(meters: distanceRemaining)
    }

    var availableTones: [AlarmService.ToneID] {
        AlarmService.ToneID.allCases
    }

    var recentCustomPlace: CustomPlace? {
        customPlaces
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .first
    }

    var quickPlaces: [QuickPlace] {
        var result: [QuickPlace] = [.home, .work]
        if recentCustomPlace != nil { result.append(.recentCustom) }
        result.append(.add)
        return result
    }

    var isHomeSet: Bool {
        !isPlaceholderSavedPlace(homePlace, quickPlace: .home)
    }

    var isWorkSet: Bool {
        !isPlaceholderSavedPlace(workPlace, quickPlace: .work)
    }

    var pendingQuickPlaceSaveLabel: String? {
        pendingQuickPlaceSave?.displayName
    }

    func updateDistanceUnitSystem(_ newValue: DistanceUnitSystem) {
        distanceUnitSystem = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: settingsDistanceUnitKey)
    }

    func updateSelectedToneID(_ newTone: AlarmService.ToneID) {
        selectedToneID = newTone
        UserDefaults.standard.set(newTone.rawValue, forKey: settingsToneIDKey)
        alarmService.setTone(newTone)
    }

    func useQuickPlace(_ quickPlace: QuickPlace) -> QuickPlaceSelectionResult {
        switch quickPlace {
        case .home:
            guard isHomeSet else {
                pendingQuickPlaceSave = .home
                statusText = "Home is not set. Pick a location and save it as Home."
                return .needsHomeSetup
            }
            useSavedPlace(homePlace)
            return .used
        case .work:
            guard isWorkSet else {
                pendingQuickPlaceSave = .work
                statusText = "Work is not set. Pick a location and save it as Work."
                return .needsWorkSetup
            }
            useSavedPlace(workPlace)
            return .used
        case .recentCustom:
            if let recentCustomPlace {
                useCustomPlace(recentCustomPlace.id)
                return .used
            }
            return .noAction
        case .add:
            return .noAction
        }
    }

    func setHomeFromSelectedDestination() {
        guard let selectedDestination else { return }
        homePlace = renamedDestination(selectedDestination, name: "Home")
        if pendingQuickPlaceSave == .home {
            pendingQuickPlaceSave = nil
        }
        persistPlaces()
        statusText = "Home updated."
    }

    func setWorkFromSelectedDestination() {
        guard let selectedDestination else { return }
        workPlace = renamedDestination(selectedDestination, name: "Work")
        if pendingQuickPlaceSave == .work {
            pendingQuickPlaceSave = nil
        }
        persistPlaces()
        statusText = "Work updated."
    }

    func savePendingQuickPlaceFromSelectedDestination() {
        guard let pendingQuickPlaceSave else { return }
        switch pendingQuickPlaceSave {
        case .home:
            setHomeFromSelectedDestination()
        case .work:
            setWorkFromSelectedDestination()
        }
    }

    func addCustomPlaceFromSelectedDestination(label: String) {
        guard let selectedDestination else { return }
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        guard !trimmed.isEmpty else {
            statusText = "Custom label is required."
            return
        }
        let destination = renamedDestination(selectedDestination, name: trimmed)
        let custom = CustomPlace(label: trimmed, destination: destination, lastUsedAt: .now)
        customPlaces.insert(custom, at: 0)
        persistPlaces()
        statusText = "Custom place \(trimmed) added."
    }

    func updateCustomPlaceLabel(id: UUID, label: String) {
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        guard !trimmed.isEmpty else { return }
        guard let idx = customPlaces.firstIndex(where: { $0.id == id }) else { return }
        customPlaces[idx].label = trimmed
        customPlaces[idx].destination.name = trimmed
        persistPlaces()
    }

    func deleteCustomPlace(id: UUID) {
        customPlaces.removeAll { $0.id == id }
        persistPlaces()
    }

    func useCustomPlace(_ id: UUID) {
        guard let idx = customPlaces.firstIndex(where: { $0.id == id }) else { return }
        customPlaces[idx].lastUsedAt = .now
        let place = customPlaces[idx]
        persistPlaces()
        useSavedPlace(renamedDestination(place.destination, name: place.label))
    }

    func resetAlarmAndTarget() {
        disarmAlarm()
        selectedDestination = nil
        isDestinationConfirmed = false
        pendingQuickPlaceSave = nil
        query = ""
        completionResults = []
        distanceRemaining = nil
        statusText = "Reset complete."
    }

    private func scheduleAutocomplete() {
        autocompleteTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completionResults = []
            return
        }
        autocompleteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.completer.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.completionResults = Array(completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        Task { @MainActor in
            self.completionResults = []
            self.statusText = "Autocomplete failed: \(error.localizedDescription)"
        }
    }

    private func restoreActiveAlarm() {
        guard
            let data = UserDefaults.standard.data(forKey: activeAlarmKey),
            let destination = try? JSONDecoder().decode(Destination.self, from: data)
        else {
            return
        }
        selectedDestination = destination
        radiusMeters = destination.radiusMeters
        armAlarm()
        statusText = "Restored armed alarm for \(destination.name)."
    }

    private func persistActiveAlarm(_ destination: Destination) {
        if let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: activeAlarmKey)
        }
    }

    private func clearActiveAlarm() {
        UserDefaults.standard.removeObject(forKey: activeAlarmKey)
    }

    private func restorePlaces() {
        if
            let data = UserDefaults.standard.data(forKey: homePlaceKey),
            let decoded = try? JSONDecoder().decode(Destination.self, from: data)
        {
            homePlace = decoded
        } else {
            homePlace = .savedHome
        }

        if
            let data = UserDefaults.standard.data(forKey: workPlaceKey),
            let decoded = try? JSONDecoder().decode(Destination.self, from: data)
        {
            workPlace = decoded
        } else {
            workPlace = .savedWork
        }

        if
            let data = UserDefaults.standard.data(forKey: customPlacesKey),
            let decoded = try? JSONDecoder().decode([CustomPlace].self, from: data)
        {
            customPlaces = decoded
        } else {
            customPlaces = []
        }
    }

    private func persistPlaces() {
        if let homeData = try? JSONEncoder().encode(homePlace) {
            UserDefaults.standard.set(homeData, forKey: homePlaceKey)
        }
        if let workData = try? JSONEncoder().encode(workPlace) {
            UserDefaults.standard.set(workData, forKey: workPlaceKey)
        }
        if let customData = try? JSONEncoder().encode(customPlaces) {
            UserDefaults.standard.set(customData, forKey: customPlacesKey)
        }
    }

    private func restoreSettings() {
        if
            let rawUnit = UserDefaults.standard.string(forKey: settingsDistanceUnitKey),
            let savedUnit = DistanceUnitSystem(rawValue: rawUnit)
        {
            distanceUnitSystem = savedUnit
        }

        if let rawTone = UserDefaults.standard.string(forKey: settingsToneIDKey) {
            if let savedTone = AlarmService.ToneID(rawValue: rawTone) {
                selectedToneID = savedTone
            } else if let migrated = migrateLegacyToneID(rawTone) {
                selectedToneID = migrated
                UserDefaults.standard.set(migrated.rawValue, forKey: settingsToneIDKey)
            }
        }
    }

    private func formatDistance(meters: Double) -> String {
        switch distanceUnitSystem {
        case .metric:
            if meters < 1000 {
                return "\(Int(meters)) m"
            }
            return String(format: "%.1f km", meters / 1000)
        case .imperial:
            let miles = meters / 1609.344
            if miles < 1 {
                let feet = meters * 3.28084
                return "\(Int(feet)) ft"
            }
            return String(format: "%.1f mi", miles)
        }
    }

    private func renamedDestination(_ destination: Destination, name: String) -> Destination {
        var copy = destination
        copy.name = name
        return copy
    }

    private func isPlaceholderSavedPlace(_ destination: Destination, quickPlace: QuickPlace) -> Bool {
        switch quickPlace {
        case .home:
            return destination.id == Destination.savedHome.id
        case .work:
            return destination.id == Destination.savedWork.id
        case .recentCustom, .add:
            return false
        }
    }

    private func migrateLegacyToneID(_ legacyValue: String) -> AlarmService.ToneID? {
        switch legacyValue {
        case "toneTriTone", "toneOpening":
            return .systemDefault
        case "toneXylophone", "alertChime":
            return .tonePulse
        case "alertBell":
            return .toneBeacon
        case "alertGlass":
            return .toneEcho
        default:
            return nil
        }
    }
}
