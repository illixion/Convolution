/*
 Hypnos - Sleep timer settings

 The sections of Settings → Sleep Timer, as sections so tvOS can place them in
 its own form: the timer itself, the accessories to set when it ends, and the
 two homes (Home Assistant, HomeKit) those accessories live in.
 */

import RAVEHome
import SwiftUI

struct SleepTimerSettingsSections: View {
    @Bindable private var timer = SleepTimer.shared
    private let home = SleepHome.shared

    @State private var haURL = ""
    @State private var haToken = ""

    var body: some View {
        timerSection
        actionsSection
        homeAssistantSection
        homeKitSection
            .task {
                haURL = home.config.baseURL
                haToken = home.config.accessToken
                home.prepareConfigured()
            }
    }

    // MARK: - Timer

    private var timerSection: some View {
        Section {
            Picker("Default Length", selection: $timer.defaultMinutes) {
                ForEach(SleepTimer.presets, id: \.self) { Text(SleepTimer.label(minutes: $0)).tag($0) }
            }
            if let end = timer.endDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Time Left", value: timer.remainingBadge(at: context.date) ?? "")
                        .monospacedDigit()
                        .accessibilityIdentifier(A11y.SleepTimerUI.timeLeft)
                }
                LabeledContent("Ends At", value: end.formatted(date: .omitted, time: .shortened))
                Button("Add 15 Minutes") { timer.extend(byMinutes: 15) }
                Button("Cancel Timer", role: .destructive) { timer.cancel() }
                    .accessibilityIdentifier(A11y.SleepTimerUI.cancel)
            } else {
                Button("Start Timer") { timer.start() }
                    .accessibilityIdentifier(A11y.SleepTimerUI.start)
            }
            if let run = timer.lastRun { lastRunRow(run) }
        } header: {
            Text("Sleep Timer")
        } footer: {
            #if os(iOS) || os(tvOS)
            Text("When the timer ends, video and music pause and the screen is allowed to lock, so a display on the HDMI output goes dark with it. Start it from the moon button in any player.")
            #else
            Text("When the timer ends, video and music pause. Start it from the moon button in any player.")
            #endif
        }
    }

    @ViewBuilder private func lastRunRow(_ run: SleepTimer.Run) -> some View {
        if let outcomes = run.outcomes {
            let failed = run.failures.count
            VStack(alignment: .leading, spacing: 2) {
                Label(failed == 0 ? "Last timer finished" : "Last timer finished with problems",
                      systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failed == 0 ? .green : .orange)
                Text(runSummary(run, total: outcomes.count))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Label {
                Text("Setting accessories…")
            } icon: {
                ProgressView()
            }
        }
    }

    private func runSummary(_ run: SleepTimer.Run, total: Int) -> String {
        let when = run.date.formatted(date: .omitted, time: .shortened)
        let players = run.pausedPlayers == 1 ? "paused 1 player" : "paused \(run.pausedPlayers) players"
        guard total > 0 else { return "\(when) · \(players)" }
        return "\(when) · \(players) · \(total - run.failures.count) of \(total) accessories set"
    }

    // MARK: - Accessory actions

    private var actionsSection: some View {
        Section {
            Toggle("Set Accessories", isOn: $timer.homeActionsEnabled)
            ForEach(timer.homeActions) { action in
                NavigationLink {
                    SleepTimerActionEditor(editing: action)
                } label: {
                    SleepTimerActionRow(action: action, outcome: outcome(for: action))
                }
            }
            #if !os(tvOS)
            .onDelete { timer.remove(at: $0) }
            #endif
            NavigationLink {
                SleepTimerAccessoryPicker()
            } label: {
                Label("Add Accessory", systemImage: "plus.circle")
            }
            .accessibilityIdentifier(A11y.SleepTimerUI.addAccessory)
            if !timer.homeActions.isEmpty {
                Button("Run Now") { timer.runHomeActions() }
            }
        } header: {
            Text("When the Timer Ends")
        } footer: {
            Text("Set lights, a smart plug on the external display, a lock or a scene to the state you choose, from Home Assistant or HomeKit. They run in this order, after playback has paused.")
        }
    }

    private func outcome(for action: HomeActionTarget) -> HomeActionOutcome? {
        timer.lastRun?.outcomes?.first { $0.id == action.id }
    }

    // MARK: - Home Assistant

    private var haChanged: Bool {
        haURL.trimmingCharacters(in: .whitespacesAndNewlines) != home.config.baseURL
            || haToken.trimmingCharacters(in: .whitespacesAndNewlines) != home.config.accessToken
    }

    private var homeAssistantSection: some View {
        Section {
            TextField("Server URL", text: $haURL, prompt: Text("https://home.example.com"))
                #if os(iOS) || os(visionOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .accessibilityIdentifier(A11y.SleepTimerUI.haURL)
            SecureField("Long-Lived Access Token", text: $haToken)
                .accessibilityIdentifier(A11y.SleepTimerUI.haToken)
            Button(home.config.isConfigured ? "Save and Reconnect" : "Save and Connect") {
                home.saveHomeAssistant(url: haURL, token: haToken)
            }
            .disabled(!haChanged || haURL.trimmingCharacters(in: .whitespaces).isEmpty
                      || haToken.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier(A11y.SleepTimerUI.haSave)
            if home.config.isConfigured {
                SleepHomeStatusRow(source: .homeAssistant, status: home.homeAssistant.status,
                                   detail: home.homeAssistant.statusDetail)
                    .accessibilityIdentifier(A11y.SleepTimerUI.haStatus)
                Button("Remove", role: .destructive) {
                    home.saveHomeAssistant(url: "", token: "")
                    haURL = ""
                    haToken = ""
                }
            }
        } header: {
            Text("Home Assistant")
        } footer: {
            Text("Create a long-lived access token on your Home Assistant profile page, under Security. The token is kept in the Keychain.")
        }
    }

    // MARK: - HomeKit

    @ViewBuilder private var homeKitSection: some View {
        if HomeSource.homeKit.isSupportedOnThisPlatform {
            Section {
                Toggle("Use HomeKit", isOn: Binding(get: { home.homeKitEnabled },
                                                    set: { home.setHomeKitEnabled($0) }))
                    .accessibilityIdentifier(A11y.SleepTimerUI.homeKitToggle)
                if home.homeKitEnabled {
                    TimelineView(.periodic(from: .now, by: 2)) { context in
                        if home.homeKit.isSilent(at: context.date) {
                            Label("HomeKit isn't responding. This build may be signed without the HomeKit capability.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            SleepHomeStatusRow(source: .homeKit, status: home.homeKit.status,
                                               detail: home.homeKit.statusDetail)
                        }
                    }
                    .accessibilityIdentifier(A11y.SleepTimerUI.homeKitStatus)
                }
            } header: {
                Text("HomeKit")
            } footer: {
                Text("Turning this on asks for access to your home. Your homes and their accessories are read on this device only.")
            }
        } else {
            Section {
                Label("HomeKit isn't available on the Mac", systemImage: "homekit")
                    .foregroundStyle(.secondary)
            } header: {
                Text("HomeKit")
            } footer: {
                Text("Apple doesn't offer HomeKit to Mac apps. Home Assistant works here, and HomeKit accessories can be set from an iPhone, iPad, Apple TV or Apple Vision Pro.")
            }
        }
    }
}

/// A backend's connection state as a row.
struct SleepHomeStatusRow: View {
    let source: HomeSource
    let status: HomeBackendStatus
    var detail: String?

    var body: some View {
        switch status {
        case .connected:
            Label {
                Text(["Connected", detail].compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .connecting:
            Label {
                Text("Connecting…")
            } icon: {
                ProgressView()
            }
        case .idle:
            Label("Not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// An action in the list: the accessory's icon as it will look afterwards,
/// its name, room and the state it is set to, and how the last run went.
struct SleepTimerActionRow: View {
    let action: HomeActionTarget
    var outcome: HomeActionOutcome?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.2), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                Text(action.summary).font(.footnote).foregroundStyle(.secondary)
                if let message = outcome?.message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if let outcome {
                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.succeeded ? .green : .orange)
                    .accessibilityLabel(outcome.succeeded ? "Done" : "Failed")
            }
            Image(systemName: action.source.systemImage)
                .foregroundStyle(.secondary)
                .accessibilityLabel(action.source.title)
        }
    }
}

/// The page, for platforms that give each settings page its own form.
struct SleepTimerSettingsPage: View {
    var body: some View {
        SettingsPage("Sleep Timer") { SleepTimerSettingsSections() }
    }
}
