# Locolarm

Locolarm is an iOS location-based arrival alarm app built with SwiftUI.  
Set a destination on the map, confirm it, arm the alarm, and get alerted when you enter the configured radius.

## Features

- Search destinations with Maps autocomplete and resolve place results.
- Pick a destination from map center with one tap.
- Configure arrival radius from 100 m to 5000 m.
- Quick places for Home, Work, and custom saved places.
- Alarm workflow with arm, ring, snooze, dismiss, and reset.
- Road distance display in metric or imperial units (Apple Maps route distance).
- Alarm tone selection with bundled tones and system fallback sounds.
- Background location monitoring with geofence support.
- Power saver mode that uses geofence-only tracking.

## Tech Stack

- SwiftUI for UI and app flow.
- MapKit for map rendering, search completions, and place lookup.
- CoreLocation for geofence and location monitoring.
- UserNotifications for arrival notifications.
- AVFAudio and AudioToolbox for alarm playback.
- UserDefaults for local persistence of settings and saved places.

## Project Structure

- `Locolarm/ContentView.swift` - Main UI, map interaction, sheets, and user actions.
- `Locolarm/AlarmViewModel.swift` - App state, business logic, persistence, and feature orchestration.
- `Locolarm/LocationService.swift` - Location permissions, geofence setup, distance tracking, and arrival detection.
- `Locolarm/AlarmService.swift` - Alarm state, playback loop, and local notification scheduling.
- `Locolarm/PowerModeService.swift` - Observes iOS Low Power Mode and updates behavior.
- `Locolarm/Destination.swift` - Destination and custom place models.
- `Locolarm/Info.plist` - Background location mode configuration.

## Requirements

- macOS with Xcode installed.
- iOS 26.0 or later (deployment target/runtime requirement).
- iOS device recommended for full background/location behavior.
- Apple Developer account for signing on physical devices.

## Setup and Run

1. Clone the repository:
   - `git clone <your-repo-url>`
   - `cd Locolarm`
2. Open `Locolarm.xcodeproj` in Xcode.
3. Select the `Locolarm` scheme.
4. Set your signing team in target settings if running on a real device.
5. Build and run.

## Permissions and Background Behavior

Locolarm needs location and notification access to work correctly.

- Location permission: choose **Always Allow** for geofence/background monitoring.
- Notifications permission: allow alerts and sounds for arrival alarm notifications.
- Background mode: `location` is enabled in `Info.plist`.

If location permission is denied or limited, alarm reliability is reduced.

## How to Use

1. Search a place or move the map and tap **Use Map Center as Destination**.
2. Adjust the arrival radius.
3. Tap **Confirm Target Destination**.
4. Turn on the alarm toggle.
5. Keep the app permissions enabled and travel to the destination area.
6. Snooze or dismiss when the alarm rings.

## Distance Behavior

- The app shows **road distance remaining** based on Apple Maps routing, not straight-line distance.
- Route distance is refreshed periodically as your location changes.
- If routing is temporarily unavailable, the app briefly falls back to straight-line distance until a route is available again.

## Current Status

This project is in active development.  
Some UI, alarm tone assets, and edge-case handling may continue to evolve.
