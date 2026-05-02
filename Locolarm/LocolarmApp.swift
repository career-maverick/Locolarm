//
//  LocolarmApp.swift
//  Locolarm
//
//  Created by Chiranjeevi Ram on 4/26/26.
//

import SwiftUI

@main
/// App entry point that loads the main location alarm screen.
struct LocolarmApp: App {
    @UIApplicationDelegateAdaptor(LocolarmAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
