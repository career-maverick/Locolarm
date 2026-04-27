import CoreLocation
import Foundation
import MapKit
import Combine

@MainActor
/// Coordinates destination selection, alarm lifecycle, persistence, and UI state.
final class AlarmViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    /// Outcome returned when user taps one of the quick-place chips.
    enum QuickPlaceSelectionResult: Equatable {
        case used
        case needsHomeSetup
        case needsWorkSetup
        case noAction
    }

    /// Indicates which quick place is waiting to be saved from selected destination.
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

    /// Quick place chips displayed in UI.
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

    /// Unit system used when formatting distance values for display.
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

    /// Configures services, restores persisted state, and starts observers.
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

    /// Cancels running async observer tasks.
    deinit {
        observerTask?.cancel()
        snoozeTask?.cancel()
        autocompleteTask?.cancel()
    }

    /// Resolves an autocomplete result into a concrete map item.
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

    /// Uses a searched map item as the selected destination.
    func useSearchResult(_ item: MKMapItem) {
        let coordinate = item.resolvedCoordinate

        let destination = Destination(
            name: item.name ?? "Pinned Destination",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters
        )
        selectedDestination = destination
        isDestinationConfirmed = false
        statusText = "Selected \(destination.name)"
        query = item.resolvedTitleFallback ?? item.name ?? destination.name
        completionResults = []
    }

    /// Uses current map center coordinate as selected destination.
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

    /// Locks currently selected destination so alarm can be armed.
    func confirmDestination() {
        guard let selectedDestination else {
            statusText = "Select a destination first."
            return
        }
        isDestinationConfirmed = true
        statusText = "Destination locked: \(selectedDestination.name)"
    }

    /// Arms the location alarm using current destination and settings.
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

    /// Disarms monitoring and clears active alarm state.
    func disarmAlarm() {
        locationService.disarm()
        alarmService.dismissAlarm()
        lastAppliedPowerSaverMode = false
        isArmed = false
        statusText = "Alarm disarmed."
        clearActiveAlarm()
    }

    /// Selects one of the persisted places and resets confirmation.
    func useSavedPlace(_ place: Destination) {
        selectedDestination = place
        isDestinationConfirmed = false
        radiusMeters = place.radiusMeters
        pendingQuickPlaceSave = nil
        statusText = "Selected saved place: \(place.name)"
    }

    /// Snoozes ringing alarm and automatically re-arms after delay.
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

    /// Dismisses active alarm and fully disarms tracking.
    func dismissAlarm() {
        alarmService.dismissAlarm()
        disarmAlarm()
    }

    /// Handles arrival callback by triggering alarm service.
    private func handleArrival() {
        guard let destination = selectedDestination else { return }
        alarmService.triggerArrivalAlarm(destinationName: destination.name)
        statusText = "Arrived near \(destination.name). Alarm started."
    }

    /// Re-arms destination tracking after snooze period finishes.
    private func rearmAfterSnooze() {
        guard let destination = selectedDestination else { return }
        locationService.arm(destination: destination, usePowerSaverOnly: effectivePowerSaverMode)
        lastAppliedPowerSaverMode = effectivePowerSaverMode
        isArmed = true
        statusText = "Snooze ended. Alarm re-armed."
    }

    /// Subscribes to service publishers and mirrors them into view state.
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

    /// Title text for a search completion row.
    func completionTitle(_ completion: MKLocalSearchCompletion) -> String {
        completion.title.isEmpty ? completion.subtitle : completion.title
    }

    /// Subtitle text for a search completion row.
    func completionSubtitle(_ completion: MKLocalSearchCompletion) -> String {
        completion.title.isEmpty ? "" : completion.subtitle
    }

    /// Formatted arrival radius display string.
    var radiusDisplayText: String {
        formatDistance(meters: radiusMeters)
    }

    /// Formatted remaining-distance text if distance is available.
    var distanceRemainingDisplayText: String? {
        guard let distanceRemaining else { return nil }
        return formatDistance(meters: distanceRemaining)
    }

    /// Alarm tones user can choose from in settings.
    var availableTones: [AlarmService.ToneID] {
        AlarmService.ToneID.allCases
    }

    /// Most recently used custom place, if any.
    var recentCustomPlace: CustomPlace? {
        customPlaces
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .first
    }

    /// Ordered quick-place chips to render.
    var quickPlaces: [QuickPlace] {
        var result: [QuickPlace] = [.home, .work]
        if recentCustomPlace != nil { result.append(.recentCustom) }
        result.append(.add)
        return result
    }

    /// True when Home is configured with a real destination.
    var isHomeSet: Bool {
        !isPlaceholderSavedPlace(homePlace, quickPlace: .home)
    }

    /// True when Work is configured with a real destination.
    var isWorkSet: Bool {
        !isPlaceholderSavedPlace(workPlace, quickPlace: .work)
    }

    /// Label for pending quick-place save action, if any.
    var pendingQuickPlaceSaveLabel: String? {
        pendingQuickPlaceSave?.displayName
    }

    /// Persists selected distance unit system.
    func updateDistanceUnitSystem(_ newValue: DistanceUnitSystem) {
        distanceUnitSystem = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: settingsDistanceUnitKey)
    }

    /// Persists selected alarm tone and applies it immediately.
    func updateSelectedToneID(_ newTone: AlarmService.ToneID) {
        selectedToneID = newTone
        UserDefaults.standard.set(newTone.rawValue, forKey: settingsToneIDKey)
        alarmService.setTone(newTone)
    }

    /// Handles quick-place taps and returns resulting action status.
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

    /// Saves selected destination as Home.
    func setHomeFromSelectedDestination() {
        guard let selectedDestination else { return }
        homePlace = renamedDestination(selectedDestination, name: "Home")
        if pendingQuickPlaceSave == .home {
            pendingQuickPlaceSave = nil
        }
        persistPlaces()
        statusText = "Home updated."
    }

    /// Saves selected destination as Work.
    func setWorkFromSelectedDestination() {
        guard let selectedDestination else { return }
        workPlace = renamedDestination(selectedDestination, name: "Work")
        if pendingQuickPlaceSave == .work {
            pendingQuickPlaceSave = nil
        }
        persistPlaces()
        statusText = "Work updated."
    }

    /// Completes pending Home/Work save action.
    func savePendingQuickPlaceFromSelectedDestination() {
        guard let pendingQuickPlaceSave else { return }
        switch pendingQuickPlaceSave {
        case .home:
            setHomeFromSelectedDestination()
        case .work:
            setWorkFromSelectedDestination()
        }
    }

    /// Adds selected destination as a labeled custom place.
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

    /// Renames a custom place and its destination label.
    func updateCustomPlaceLabel(id: UUID, label: String) {
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        guard !trimmed.isEmpty else { return }
        guard let idx = customPlaces.firstIndex(where: { $0.id == id }) else { return }
        customPlaces[idx].label = trimmed
        customPlaces[idx].destination.name = trimmed
        persistPlaces()
    }

    /// Deletes a custom place by id.
    func deleteCustomPlace(id: UUID) {
        customPlaces.removeAll { $0.id == id }
        persistPlaces()
    }

    /// Selects custom place and marks it as recently used.
    func useCustomPlace(_ id: UUID) {
        guard let idx = customPlaces.firstIndex(where: { $0.id == id }) else { return }
        customPlaces[idx].lastUsedAt = .now
        let place = customPlaces[idx]
        persistPlaces()
        useSavedPlace(renamedDestination(place.destination, name: place.label))
    }

    /// Clears armed alarm, selected destination, and transient UI state.
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

    /// Debounces user search input before requesting autocomplete results.
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

    /// Receives autocomplete updates from MapKit completer.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.completionResults = Array(completer.results.prefix(8))
        }
    }

    /// Handles autocomplete failures and updates status text.
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        Task { @MainActor in
            self.completionResults = []
            self.statusText = "Autocomplete failed: \(error.localizedDescription)"
        }
    }

    /// Restores any previously armed destination alarm from persistence.
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

    /// Persists currently armed destination.
    private func persistActiveAlarm(_ destination: Destination) {
        if let data = try? JSONEncoder().encode(destination) {
            UserDefaults.standard.set(data, forKey: activeAlarmKey)
        }
    }

    /// Clears persisted active alarm.
    private func clearActiveAlarm() {
        UserDefaults.standard.removeObject(forKey: activeAlarmKey)
    }

    /// Restores saved Home, Work, and custom places.
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

    /// Persists Home, Work, and custom places.
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

    /// Restores settings such as unit system and tone selection.
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

    /// Formats meter values according to selected unit system.
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

    /// Returns a destination copy with updated display name.
    private func renamedDestination(_ destination: Destination, name: String) -> Destination {
        var copy = destination
        copy.name = name
        return copy
    }

    /// Detects whether Home/Work still points to placeholder default values.
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

    /// Migrates older tone identifiers to current enum values.
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

private extension MKMapItem {
    /// Returns location coordinate from resolved map item.
    var resolvedCoordinate: CLLocationCoordinate2D {
        location.coordinate
    }

    /// Provides fallback title text from resolved map item.
    var resolvedTitleFallback: String? {
        name
    }
}
