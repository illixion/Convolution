/*
 Hypnos - The homes the sleep timer can act on

 RAVEHome's two backends and the settings that reach them: a Home Assistant
 address and token, and whether to use HomeKit. Nothing connects until it is
 asked to: a person who never sets up home actions is never shown HomeKit's
 permission prompt, and no socket is opened to a server they didn't configure.

 Everything here is configuration the sleep timer reads when it arms and when
 it ends; accessories are chosen on the sleep timer's settings page.
 */

import Foundation
import Observation
import RAVEHome

@MainActor
@Observable
final class SleepHome {
    static let shared = SleepHome()

    let homeAssistant = HAConnection()
    let homeKit = HomeKitConnection()

    private enum Key {
        static let url = "sleepTimer.homeAssistant.url"
        static let homeKit = "sleepTimer.homeKit.enabled"
    }

    /// The Home Assistant address and token as saved (the token is in the Keychain).
    private(set) var config: HAConfig

    /// Whether HomeKit may be used at all. Off until the person turns it on,
    /// which is what raises the system's HomeKit permission prompt.
    private(set) var homeKitEnabled: Bool

    private init() {
        config = HAConfig(baseURL: HypnosDefaults.store.string(forKey: Key.url) ?? "",
                          accessToken: KeychainStore.string(for: .homeAssistantToken) ?? "")
        homeKitEnabled = HypnosDefaults.store.bool(forKey: Key.homeKit)
    }

    // MARK: - Settings

    func saveHomeAssistant(url: String, token: String) {
        var next = HAConfig(baseURL: url, accessToken: token)
        next.baseURL = next.trimmedBaseURL
        next.accessToken = next.trimmedToken
        HypnosDefaults.store.set(next.baseURL, forKey: Key.url)
        KeychainStore.set(next.accessToken, for: .homeAssistantToken)
        config = next
        // A changed address or token is a different server: connect afresh.
        if next.isConfigured { homeAssistant.connect(config: next) } else { homeAssistant.disconnect() }
    }

    func setHomeKitEnabled(_ enabled: Bool) {
        homeKitEnabled = enabled
        HypnosDefaults.store.set(enabled, forKey: Key.homeKit)
        if enabled { homeKit.activate() }
    }

    // MARK: - Backends

    /// The backend for a source, or nil when it isn't usable here (not set up,
    /// or HomeKit on a Mac).
    func backend(for source: HomeSource) -> (any HomeBackend)? {
        switch source {
        case .homeAssistant: return config.isConfigured ? homeAssistant : nil
        case .homeKit: return homeKitEnabled && source.isSupportedOnThisPlatform ? homeKit : nil
        }
    }

    /// The sources a person can pick accessories from right now.
    var availableSources: [HomeSource] {
        HomeSource.allCases.filter { backend(for: $0) != nil }
    }

    /// Bring up the connections `sources` need (and only those), so they are
    /// ready by the time something is applied. Safe to call repeatedly: a
    /// live connection is left alone, a dead one is retried.
    func prepare(for sources: Set<HomeSource>) {
        if sources.contains(.homeAssistant), config.isConfigured {
            if homeAssistant.canStartConnection || homeAssistant.activeConfig != config {
                homeAssistant.connect(config: config)
            } else if !homeAssistant.isConnected {
                homeAssistant.probeOrReconnect()
            }
        }
        if sources.contains(.homeKit), homeKitEnabled { homeKit.activate() }
    }

    /// The sources that are set up, for opening the settings page or picker.
    func prepareConfigured() {
        prepare(for: Set(HomeSource.allCases.filter { backend(for: $0) != nil }))
    }
}
