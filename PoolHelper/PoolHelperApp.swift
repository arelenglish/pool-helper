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
            ContentView(store: Self.demoStore(), opensSetupImmediately: Self.opensSetup)
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
    /// Opens the setup sheet at launch, for inspecting it without the hidden gesture. Gated
    /// behind `-demo` so it can never be a way into a real kiosk's account screen.
    private static var opensSetup: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-setup")
    }

    private static func demoStore() -> PoolStore? {
        guard ProcessInfo.processInfo.arguments.contains("-demo") else { return nil }
        let demoDefaults = UserDefaults(suiteName: "demo")!
        let client = MockIAqualinkClient()
        client.latency = 400_000_000  // makes the optimistic-update path visible
        return PoolStore(
            client: client,
            schedule: .heater(defaults: demoDefaults),
            jetsSchedule: .jets(defaults: demoDefaults),
            lightsSchedule: .lights(defaults: demoDefaults),
            credentials: .inMemory(.init(email: "demo@example.com", password: "demo")),
            pollInterval: .seconds(5)
        )
    }
}
