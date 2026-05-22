//
//  ChargeLinkApp.swift
//  ChargeLink
//

import SwiftUI

@main
struct ChargeLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder scene — UI lives in AppDelegate's NSStatusItem. Window never shown.
        WindowGroup {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
