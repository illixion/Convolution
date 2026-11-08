/*
 Hypnos - Settings → AI Features → Smart Activation (visionOS, iOS, macOS)

 The rules that turn Smooth Motion and AI Upscaling on or off per video
 (`SmartActivation`, `SmartRules`): a list for each feature, checked top to
 bottom, edited here. Not on tvOS, whose player has neither feature.
 */

#if !os(tvOS)
import SwiftUI

struct SmartActivationSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    /// For the row that opens this page.
    @MainActor static func statusLabel(_ appModel: AppModel) -> String {
        var on: [String] = []
        #if os(visionOS)
        if appModel.smartSmoothMotion { on.append("Smooth Motion") }
        #endif
        if appModel.smartUpscaling { on.append("Upscaling") }
        return on.isEmpty ? "Off" : on.joined(separator: ", ")
    }

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Smart Activation") {
            Section {
                Text("Choose which videos get a feature without turning it on for all of them. Rules are checked from the top, and the first one that fits a video decides for it. A video no rule fits follows the default in AI Features. A video's View Mode menu still has the last word.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            #if os(visionOS)
            featureSection(
                "Smooth Motion", isOn: $appModel.smartSmoothMotion, rules: $appModel.smartRules.smoothMotion,
                boosts: true, defaultOn: appModel.smoothMotion,
                note: "A video is boosted to twice its frame rate, so a rule for 24–30 fps boosts to 48–60 fps, and leaving out 50–60 fps keeps those from reaching 100–120.")
            #endif
            featureSection(
                "AI Upscaling", isOn: $appModel.smartUpscaling, rules: $appModel.smartRules.upscaling,
                boosts: false, defaultOn: appModel.aiUpscaling,
                note: "Upscaling only ever runs on pictures of 720p and below that are not HDR, so a rule for a bigger picture changes nothing.")

            Section {
                Button("Restore Suggested Rules", role: .destructive) {
                    appModel.smartRules = .suggested
                }
                .disabled(appModel.smartRules == .suggested)
            } footer: {
                Text("Suggested: hold back in Low Power Mode and when the device is hot, give Smooth Motion to 24–30 fps videos, and give AI Upscaling to pictures of 720p and below.")
            }
        }
        #if !os(macOS)
        .toolbar { EditButton() }
        #endif
    }

    @ViewBuilder
    private func featureSection(_ name: String, isOn: Binding<Bool>, rules: Binding<[SmartRule]>,
                                boosts: Bool, defaultOn: Bool, note: String) -> some View {
        Section {
            Toggle("Use Rules for \(name)", isOn: isOn)
            if isOn.wrappedValue {
                ForEach(rules) { $rule in
                    NavigationLink {
                        SmartRuleEditor(rule: $rule, feature: name, boosts: boosts)
                    } label: {
                        SmartRuleRow(rule: rule, boosts: boosts)
                    }
                }
                .onDelete { rules.wrappedValue.remove(atOffsets: $0) }
                .onMove { rules.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    rules.wrappedValue.append(SmartRule())
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
        } header: {
            Text(name)
        } footer: {
            if isOn.wrappedValue {
                Text("Videos no rule fits: \(name) \(defaultOn ? "on" : "off") (the default). \(note)")
            } else {
                Text("Off: \(name) follows the default alone (\(defaultOn ? "on" : "off")).")
            }
        }
    }
}

/// A rule in the list: what it does, and to which videos.
private struct SmartRuleRow: View {
    let rule: SmartRule
    let boosts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(rule.turnsOn ? "Turn On" : "Turn Off",
                  systemImage: rule.turnsOn ? "checkmark.circle" : "xmark.circle")
            Text(rule.summary(boosts: boosts) + (rule.isEnabled ? "" : " · paused"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(rule.isEnabled ? 1 : 0.5)
    }
}

/// One rule's action and conditions.
private struct SmartRuleEditor: View {
    @Binding var rule: SmartRule
    let feature: String
    let boosts: Bool

    var body: some View {
        SettingsPage("\(feature) Rule") {
            Section {
                Picker("Action", selection: $rule.turnsOn) {
                    Text("Turn On").tag(true)
                    Text("Turn Off").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Rule Is Active", isOn: $rule.isEnabled)
            } footer: {
                Text(rule.turnsOn ? "Turns \(feature) on for the videos below." : "Keeps \(feature) off for the videos below.")
            }

            Section {
                choice("Frame Rate At Least", $rule.minFrameRate, SmartRule.frameRateChoices) { "\(Int($0)) fps" }
                choice("Frame Rate At Most", $rule.maxFrameRate, SmartRule.frameRateChoices) { "\(Int($0)) fps" }
                if boosts {
                    choice("Boosted To At Most", $rule.maxBoostedFrameRate, SmartRule.boostedRateChoices) { "\(Int($0)) fps" }
                }
                choice("Picture Up To", $rule.maxResolution, SmartResolution.allCases) { $0.label }
                Toggle("Only Non-HDR Pictures", isOn: $rule.sdrOnly)
                Picker("Device", selection: $rule.whenStrained) {
                    Text("Any").tag(Bool?.none)
                    Text("Low Power Mode or Hot").tag(Bool?.some(true))
                    Text("Power to Spare").tag(Bool?.some(false))
                }
                .pickerStyle(.menu)
            } header: {
                Text("When the Video Has")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Applies to: \(rule.summary(boosts: boosts)). A setting left on Any is not checked.")
                    if let low = rule.minFrameRate, let high = rule.maxFrameRate, low > high {
                        Text("The lowest frame rate is above the highest, so this rule never fits.")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func choice<T: Hashable>(_ title: String, _ selection: Binding<T?>, _ options: [T],
                                     label: @escaping (T) -> String) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(T?.none)
            ForEach(options, id: \.self) { Text(label($0)).tag(T?.some($0)) }
        }
        .pickerStyle(.menu)
    }
}
#endif
