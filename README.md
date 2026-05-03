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
- Power saver mode that uses geofence-only tracking (also follows system Low Power Mode).
- **ETA fallback:** optional route-based timer from your last Apple Maps ETA; can ring if GPS is stale or unavailable (e.g. tunnel, garage), with a clear in-app warning that the alert is approximate.
- **AlarmKit:** when authorized, iOS shows a system arrival alarm and an ETA-deadline alarm that can break through Silent mode and Focus; dismissing the alert runs App Intents wired to stop audio or evaluate the fallback.
- **Lock Screen / Control Center:** looping alarm audio uses a playback session with Now Playing metadata; pause/stop ends the alarm like in-app dismiss.
- **Foreground recovery:** audio resumes after interruptions and when the app becomes active again.

## Tech Stack

- SwiftUI for UI and app flow.
- MapKit for map rendering, search completions, place lookup, and route distance/ETA.
- CoreLocation for geofence and location monitoring.
- UserNotifications for arrival notifications and ETA deadline delivery.
- **AlarmKit** and **App Intents** (`LiveActivityIntent`) for system alarms and stop/dismiss actions.
- AVFAudio and AudioToolbox for alarm playback.
- MediaPlayer for Now Playing and remote transport controls.
- `UIApplicationDelegateAdaptor` for notification delegate callbacks and foreground hooks.
- UserDefaults for local persistence of settings and saved places.

## Project Structure

- `Locolarm/ContentView.swift` - Main UI, map interaction, sheets, and user actions.
- `Locolarm/AlarmViewModel.swift` - App state, business logic, persistence, ETA fallback setting, and AlarmKit authorization surfacing.
- `Locolarm/LocationService.swift` - Location permissions, geofence setup, distance tracking, arrival detection, and ETA fallback scheduling/evaluation.
- `Locolarm/AlarmService.swift` - Alarm state, playback loop, notifications, AlarmKit scheduling, and audio/session recovery.
- `Locolarm/LocolarmAppDelegate.swift` - `UNUserNotificationCenter` delegate, ETA deadline forwarding, and active-alarm recovery on `applicationDidBecomeActive`.
- `Locolarm/LocolarmApp.swift` - App entry; attaches `LocolarmAppDelegate`.
- `Locolarm/LocolarmAlarmIntents.swift` - `StopArrivalAlarmIntent` and `EvaluateEtaFallbackAlarmIntent` for AlarmKit stop buttons.
- `Locolarm/LocolarmAlarmMetadata.swift` - `AlarmMetadata` type for AlarmKit alarm configurations.
- `Locolarm/ETAFallbackConstants.swift` - Stale-GPS thresholds, notification name, and tuning constants for ETA fallback.
- `Locolarm/PowerModeService.swift` - Observes iOS Low Power Mode and updates behavior.
- `Locolarm/Destination.swift` - Destination and custom place models.
- `Locolarm/Info.plist` - Background modes (`location`, `audio`), AlarmKit usage description.

## Requirements

- macOS with Xcode installed.
- iOS 26.4 or later (deployment target in the Xcode project).
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

Locolarm needs location, notifications, and (for system alarms) AlarmKit access to work as designed.

- **Location:** choose **Always Allow** for geofence/background monitoring.
- **Notifications:** allow alerts and sounds for arrival and ETA deadline notifications.
- **AlarmKit:** grant access when prompted so system alarms can align with Silent/Focus behavior described in Settings copy inside the app.
- **Background modes** in `Info.plist`: `location` and `audio` (continuous alarm loop while ringing).

If location permission is denied or limited, alarm reliability is reduced. If ETA fallback is disabled, only GPS/geofence-style detection applies once routes stop updating meaningfully.

## How to Use

1. Search a place or move the map and tap **Use Map Center as Destination**.
2. Adjust the arrival radius.
3. Tap **Confirm Target Destination**.
4. Optionally adjust **ETA fallback when GPS is lost** in settings if you want route-timer backup alerts.
5. Turn on the alarm toggle (AlarmKit authorization may be requested when arming).
6. Keep the app permissions enabled and travel to the destination area.
7. Snooze or dismiss when the alarm rings; if a system AlarmKit alert appears, dismissing it can stop in-app audio or trigger fallback evaluation depending on which alarm fired.

## Distance and Arrival Behavior

- The app shows **road distance remaining** based on Apple Maps routing when possible, not straight-line distance alone.
- Route distance and ETA refresh periodically as your location changes (with throttling to limit MapKit load).
- If routing is temporarily unavailable, the app can fall back to straight-line distance until a route is available again.
- **GPS-confirmed arrival:** geofence entry and/or distance inside your radius triggers a normal arrival alarm.
- **ETA fallback arrival:** when enabled, if the **deadline from the last route ETA** passes and GPS is missing, stale, or ambiguous, the app may fire an **approximate** arrival path; the UI shows an explicit warning to confirm you are actually near your stop. Fresh GPS far beyond the radius can suppress firing.

## Current Status

This project is in active development.  
Some UI, alarm tone assets, and edge-case handling may continue to evolve.
