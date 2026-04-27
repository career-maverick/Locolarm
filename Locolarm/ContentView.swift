//
//  ContentView.swift
//  Locolarm
//
//  Created by Chiranjeevi Ram on 4/26/26.
//

import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AlarmViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapCenterCoordinate = CLLocationCoordinate2D(latitude: 12.9716, longitude: 77.5946)
    @State private var mapDidRender = false
    @State private var isShowingSettings = false
    @State private var isShowingLocations = false
    @State private var isShowingAbout = false
    @State private var hasCenteredOnCurrentLocation = false
    @State private var customLabelInput = ""
    @State private var quickPlaceAlertMessage = ""
    @State private var isShowingQuickPlaceAlert = false
    @FocusState private var isSearchFieldFocused: Bool

    private var alarmToggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isArmed },
            set: { isOn in
                if isOn {
                    viewModel.armAlarm()
                } else {
                    viewModel.disarmAlarm()
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Map(position: $cameraPosition) {
                        if let destination = viewModel.selectedDestination {
                            Marker(destination.name, coordinate: destination.coordinate)
                                .tint(.red)
                            MapCircle(center: destination.coordinate, radius: destination.radiusMeters)
                                .foregroundStyle(.red.opacity(0.18))
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onMapCameraChange { context in
                        if !mapDidRender {
                            mapDidRender = true
                        }

                        let newCenter = context.region.center
                        let latDiff = abs(newCenter.latitude - mapCenterCoordinate.latitude)
                        let lonDiff = abs(newCenter.longitude - mapCenterCoordinate.longitude)
                        if latDiff > 0.00005 || lonDiff > 0.00005 {
                            mapCenterCoordinate = newCenter
                        }
                    }

                    Button("Use Map Center as Destination") {
                        viewModel.usePinnedCoordinate(mapCenterCoordinate)
                        isSearchFieldFocused = false
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Search by address/place name", text: $viewModel.query)
                            .textFieldStyle(.roundedBorder)
                            .focused($isSearchFieldFocused)

                        if viewModel.isSearching {
                            ProgressView("Searching...")
                        }

                        ForEach(viewModel.completionResults, id: \.self) { completion in
                            Button {
                                Task {
                                    guard let item = await viewModel.resolveCompletion(completion) else { return }
                                    viewModel.useSearchResult(item)
                                    isSearchFieldFocused = false
                                    cameraPosition = .region(
                                        MKCoordinateRegion(
                                            center: item.placemark.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                                        )
                                    )
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(viewModel.completionTitle(completion))
                                        .font(.subheadline.weight(.semibold))
                                    let subtitle = viewModel.completionSubtitle(completion)
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved Places")
                            .font(.headline)
                        HStack {
                            ForEach(viewModel.quickPlaces) { place in
                                Button(place.title) {
                                    if place == .add {
                                        isShowingLocations = true
                                    } else {
                                        let result = viewModel.useQuickPlace(place)
                                        if result == .needsHomeSetup || result == .needsWorkSetup {
                                            quickPlaceAlertMessage = result == .needsHomeSetup
                                                ? "Home is not set yet. Search or pin a location, then save it as Home."
                                                : "Work is not set yet. Search or pin a location, then save it as Work."
                                            isShowingQuickPlaceAlert = true
                                            isSearchFieldFocused = true
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        if
                            let pendingLabel = viewModel.pendingQuickPlaceSaveLabel,
                            viewModel.selectedDestination != nil
                        {
                            Button("Save Selected Destination as \(pendingLabel)") {
                                viewModel.savePendingQuickPlaceFromSelectedDestination()
                                isSearchFieldFocused = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arrival Radius: \(viewModel.radiusDisplayText)")
                            .font(.headline)
                        Slider(value: $viewModel.radiusMeters, in: 100...5000, step: 100)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Target")
                                .font(.headline)
                            Spacer()
                            Text(viewModel.isDestinationConfirmed ? "Locked" : "Not Locked")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(viewModel.isDestinationConfirmed ? .green : .orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background((viewModel.isDestinationConfirmed ? Color.green : Color.orange).opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Button(viewModel.isDestinationConfirmed ? "Target Confirmed" : "Confirm Target Destination") {
                            viewModel.confirmDestination()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.selectedDestination == nil || viewModel.isDestinationConfirmed)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Location Alarm")
                            .font(.headline)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.selectedDestination?.name ?? "No Destination Selected")
                                    .font(.title3.weight(.semibold))
                                Text("Arrive within \(viewModel.radiusDisplayText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: alarmToggleBinding)
                                .labelsHidden()
                                .tint(.green)
                                .disabled(viewModel.selectedDestination == nil || !viewModel.isDestinationConfirmed)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                    Button("Reset") {
                        viewModel.resetAlarmAndTarget()
                    }
                    .buttonStyle(.bordered)

                    if let destination = viewModel.selectedDestination {
                        Text("Selected: \(destination.name)")
                        Text(viewModel.isDestinationConfirmed ? "Destination confirmed for alarm." : "Confirm this destination to enable alarm toggle.")
                            .font(.caption)
                            .foregroundStyle(viewModel.isDestinationConfirmed ? .green : .secondary)
                        if let distanceText = viewModel.distanceRemainingDisplayText {
                            Text("Distance remaining: \(distanceText)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .ringing = viewModel.alarmState {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Alarm is ringing")
                                .font(.headline)
                                .foregroundStyle(.red)
                            HStack {
                                Button("Snooze 5 min") { viewModel.snoozeAlarm(minutes: 5) }
                                    .buttonStyle(.borderedProminent)
                                Button("Dismiss") { viewModel.dismissAlarm() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Location Alarm")
            .onChange(of: viewModel.currentLocationCoordinate?.latitude ?? 0) { _, _ in
                guard let coordinate = viewModel.currentLocationCoordinate, !hasCenteredOnCurrentLocation else { return }
                hasCenteredOnCurrentLocation = true
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    )
                )
                mapCenterCoordinate = coordinate
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Locations") { isShowingLocations = true }
                        Button("Settings") { isShowingSettings = true }
                        Button("About") { isShowingAbout = true }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    Form {
                        Section("Tracking") {
                            Toggle("Power Saver mode (geofence only)", isOn: $viewModel.userPowerSaverMode)
                            if viewModel.lowPowerModeActive {
                                Text("Low Power Mode is ON, so geofence-only is auto-enabled.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Distance Units") {
                            Picker("Units", selection: Binding(
                                get: { viewModel.distanceUnitSystem },
                                set: { viewModel.updateDistanceUnitSystem($0) }
                            )) {
                                ForEach(AlarmViewModel.DistanceUnitSystem.allCases) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Section("Alarm Tone") {
                            Picker("Sound", selection: Binding(
                                get: { viewModel.selectedToneID },
                                set: { viewModel.updateSelectedToneID($0) }
                            )) {
                                ForEach(viewModel.availableTones, id: \.rawValue) { tone in
                                    Text(tone.displayName).tag(tone)
                                }
                            }
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                isShowingSettings = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingLocations) {
                NavigationStack {
                    Form {
                        Section("Quick Set from Selected Target") {
                            Button("Set Home to Selected Target") {
                                viewModel.setHomeFromSelectedDestination()
                            }
                            .disabled(viewModel.selectedDestination == nil)

                            Button("Set Work to Selected Target") {
                                viewModel.setWorkFromSelectedDestination()
                            }
                            .disabled(viewModel.selectedDestination == nil)
                        }

                        Section("Add Custom Place") {
                            TextField("Label (max 10 chars)", text: $customLabelInput)
                            Button("Add Custom from Selected Target") {
                                viewModel.addCustomPlaceFromSelectedDestination(label: customLabelInput)
                                customLabelInput = ""
                            }
                            .disabled(viewModel.selectedDestination == nil || customLabelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Section("Home") {
                            Text(viewModel.homePlace.name)
                        }

                        Section("Work") {
                            Text(viewModel.workPlace.name)
                        }

                        Section("Custom Places") {
                            if viewModel.customPlaces.isEmpty {
                                Text("No custom places yet.")
                            } else {
                                ForEach(viewModel.customPlaces) { place in
                                    HStack {
                                        TextField(
                                            "Label",
                                            text: Binding(
                                                get: { place.label },
                                                set: { viewModel.updateCustomPlaceLabel(id: place.id, label: String($0.prefix(10))) }
                                            )
                                        )
                                        Button("Use") {
                                            viewModel.useCustomPlace(place.id)
                                            isShowingLocations = false
                                        }
                                    }
                                }
                                .onDelete { offsets in
                                    for idx in offsets {
                                        viewModel.deleteCustomPlace(id: viewModel.customPlaces[idx].id)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Locations")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingLocations = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingAbout) {
                NavigationStack {
                    List {
                        Section("About Locolarm") {
                            Text("Location-based arrival alarm with Maps + Clock style flow.")
                            Text("Version 1.0")
                                .foregroundStyle(.secondary)
                        }
                        Section("About the Maker") {
                            Text("Built by Chiranjeevi Ramamurthy.")
                            Text("iOS builder focused on practical, user-first apps.")
                            Link("LinkedIn Profile", destination: URL(string: "https://www.linkedin.com/in/chiranjeevi-ram/")!)
                        }
                    }
                    .navigationTitle("About")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isShowingAbout = false }
                        }
                    }
                }
            }
            .alert("Location Needed", isPresented: $isShowingQuickPlaceAlert) {
                Button("Pick Location", role: .cancel) {
                    isSearchFieldFocused = true
                }
            } message: {
                Text(quickPlaceAlertMessage)
            }
        }
    }
}

#Preview {
    ContentView()
}
