//
//  DoomClimbApp.swift
//  DoomClimb
//
//  Created by Maxwell Wainwright on 4/2/26.
//

import SwiftUI

@main
struct DoomClimbApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
