//
//  LocolarmTests.swift
//  LocolarmTests
//
//  Created by Chiranjeevi Ram on 4/26/26.
//

import CoreLocation
import Foundation
import Testing
@testable import Locolarm

struct LocolarmTests {
    @Test("Destination exposes coordinate from latitude/longitude")
    func destinationCoordinateProjection() {
        let destination = Destination(
            name: "Work",
            latitude: 12.9716,
            longitude: 77.5946,
            radiusMeters: 300
        )

        #expect(destination.coordinate.latitude == 12.9716)
        #expect(destination.coordinate.longitude == 77.5946)
    }

    @Test("Custom place label is trimmed to 10 characters")
    func customPlaceLabelLimit() {
        let destination = Destination(
            name: "Station",
            latitude: 12.0,
            longitude: 77.0,
            radiusMeters: 200
        )
        let customPlace = CustomPlace(
            label: "VeryLongLabelName",
            destination: destination
        )

        #expect(customPlace.label == "VeryLongLa")
        #expect(customPlace.label.count == 10)
    }

    @Test("Default placeholders keep stable names")
    func defaultSavedPlaceNames() {
        #expect(Destination.savedHome.name == "Home")
        #expect(Destination.savedWork.name == "Work")
    }

    @Test("Tone metadata maps to expected bundled loop files")
    func toneMetadataMappings() {
        #expect(AlarmService.ToneID.systemDefault.bundledFilename == "alarm-default.wav")
        #expect(AlarmService.ToneID.toneBeacon.bundledFilename == "tone-beacon.wav")
        #expect(AlarmService.ToneID.tonePulse.bundledFilename == "tone-pulse.wav")
        #expect(AlarmService.ToneID.toneEcho.bundledFilename == "tone-echo.wav")
    }

    @Test("Tone display names are user friendly")
    func toneDisplayNames() {
        #expect(AlarmService.ToneID.systemDefault.displayName == "System Default")
        #expect(AlarmService.ToneID.toneBeacon.displayName == "Beacon")
        #expect(AlarmService.ToneID.tonePulse.displayName == "Pulse")
        #expect(AlarmService.ToneID.toneEcho.displayName == "Echo")
    }

    @Test("Distance unit labels stay consistent")
    func distanceUnitDisplayNames() {
        #expect(AlarmViewModel.DistanceUnitSystem.metric.displayName == "Kilometers")
        #expect(AlarmViewModel.DistanceUnitSystem.imperial.displayName == "Miles")
    }

    @Test("Quick place titles stay consistent")
    func quickPlaceTitles() {
        #expect(AlarmViewModel.QuickPlace.home.title == "Home")
        #expect(AlarmViewModel.QuickPlace.work.title == "Work")
        #expect(AlarmViewModel.QuickPlace.recentCustom.title == "Recent")
        #expect(AlarmViewModel.QuickPlace.add.title == "+")
    }

    @Test("ETA fallback suppress distance uses radius factor with floor")
    func etaFallbackSuppressDistanceScalesWithRadius() {
        #expect(ETAFallbackConstants.minimumSuppressDistanceMeters(arrivalRadiusMeters: 200) == 800)
        #expect(ETAFallbackConstants.minimumSuppressDistanceMeters(arrivalRadiusMeters: 500) == 1250)
    }
}
