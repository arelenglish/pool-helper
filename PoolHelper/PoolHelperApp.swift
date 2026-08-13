//
//  PoolHelperApp.swift
//  PoolHelper
//

import SwiftUI
import UIKit

@main
struct PoolHelperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(store: Self.demoStore())
                .preferredColorScheme(.dark)
                .onAppear {
                    // The iPad is wall-powered and locked to this app; letting it sleep
                    // would mean guests find a black screen and start tapping blindly.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }

    /// Launching with `-demo` drives the whole interface from an in-memory pool, so the UI
    /// can be exercised on a simulator with no credentials and no live controller. Returns
    /// nil in normal use, which makes `ContentView` build its own live store.
    private static func demoStore() -> PoolStore? {
        guard ProcessInfo.processInfo.arguments.contains("-demo") else { return nil }
        let client = MockIAqualinkClient()
        client.latency = 400_000_000  // makes the optimistic-update path visible
        return PoolStore(
            client: client,
            schedule: HeatSchedule(defaults: UserDefaults(suiteName: "demo")!),
            credentials: .inMemory(.init(email: "demo@example.com", password: "demo")),
            pollInterval: .seconds(5)
        )
    }
}
