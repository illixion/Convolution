/*
 Hypnos - Settings → On-Screen Text

 Narration of burned-in subtitles: on or off, the voice (the system's
 installed voices, best first; Personal Voice once allowed), how fast, and
 where in the picture to read. Every platform; tvOS has no Slider, so its
 speed is stepped and it has no custom area.
 */

import AVFoundation
import SwiftUI

struct OnScreenTextSettingsPage: View {
    @AppStorage(OnScreenTextSettings.narrateKey, store: HypnosDefaults.store) private var narrates = true
    @AppStorage(OnScreenTextSettings.voiceKey, store: HypnosDefaults.store) private var voiceID = ""
    @AppStorage(OnScreenTextSettings.rateKey, store: HypnosDefaults.store) private var rate = 1.0
    @AppStorage(OnScreenTextSettings.areaKey, store: HypnosDefaults.store) private var area = OnScreenTextSettings.Area.bottom.rawValue
    @AppStorage(OnScreenTextSettings.customTopKey, store: HypnosDefaults.store) private var customTop = 0.55
    @AppStorage(OnScreenTextSettings.customBottomKey, store: HypnosDefaults.store) private var customBottom = 1.0
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var preview = AVSpeechSynthesizer()

    var body: some View {
        SettingsPage("On-Screen Text") {
            Section {
                Toggle("Narrate", isOn: $narrates)
            } footer: {
                Text("Choose On-Screen Text in a video's subtitle menu for videos whose words are written on the picture instead of spoken. Text is read on this device, a few seconds ahead of the picture, and with Narrate on it is spoken in the voice below while the video's sound is lowered.")
            }

            Section("Speed") {
                #if os(tvOS)
                HStack {
                    Button("Slower") { rate = max(0.5, ((rate - 0.1) * 10).rounded() / 10) }
                    Spacer()
                    Text(String(format: "%.1f×", rate))
                    Spacer()
                    Button("Faster") { rate = min(1.5, ((rate + 0.1) * 10).rounded() / 10) }
                }
                #else
                Slider(value: $rate, in: 0.5...1.5, step: 0.05) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                Text(String(format: "%.2f× normal speed", rate)).font(.caption).foregroundStyle(.secondary)
                #endif
            }

            Section {
                voiceRow(nil)
                ForEach(voices, id: \.identifier) { voiceRow($0) }
            } header: {
                Text("Voice")
            } footer: {
                Text("Premium and Enhanced voices sound the most natural; download them in the system Settings under Accessibility → Spoken Content → Voices, then come back here. Siri's voices aren't available to apps.")
            }

            if personalVoice != .authorized, personalVoice != .unsupported {
                Section {
                    Button("Use My Personal Voice…") {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                            Task { @MainActor in
                                personalVoice = status
                                voices = OnScreenTextSettings.voices()
                            }
                        }
                    }
                    .disabled(personalVoice == .denied)
                } footer: {
                    Text(personalVoice == .denied
                         ? "Personal Voice access was declined. Allow it for Convolution in the system Settings."
                         : "Narrate in the Personal Voice you created in the system Settings.")
                }
            }

            Section {
                ForEach(availableAreas) { choice in
                    Button {
                        area = choice.rawValue
                    } label: {
                        HStack {
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if area == choice.rawValue { Image(systemName: "checkmark") }
                        }
                    }
                }
                #if !os(tvOS)
                if area == OnScreenTextSettings.Area.custom.rawValue {
                    VStack(alignment: .leading) {
                        Text(String(format: "From %.0f%% down", customTop * 100)).font(.caption)
                        Slider(value: $customTop, in: 0...0.95, step: 0.05)
                        Text(String(format: "To %.0f%% down", customBottom * 100)).font(.caption)
                        Slider(value: $customBottom, in: 0.05...1, step: 0.05)
                    }
                    .onChange(of: customTop) { _, top in if customBottom < top + 0.05 { customBottom = min(1, top + 0.05) } }
                    .onChange(of: customBottom) { _, bottom in if customTop > bottom - 0.05 { customTop = max(0, bottom - 0.05) } }
                }
                #endif
            } header: {
                Text("Where to Read")
            } footer: {
                Text("Bottom fits nearly every video. Lines centred in the area, in the size and colour the video's subtitles mostly use, are read; a game's own smaller or differently coloured subtitles and other text on screen are left out.")
            }
        }
        .task { voices = OnScreenTextSettings.voices() }
    }

    private var availableAreas: [OnScreenTextSettings.Area] {
        #if os(tvOS)
        [.bottom, .top, .whole]
        #else
        OnScreenTextSettings.Area.allCases
        #endif
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice?) -> some View {
        let id = voice?.identifier ?? ""
        Button {
            voiceID = id
            speakSample(voice)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice?.name ?? "System Default").foregroundStyle(.primary)
                    if let voice {
                        Text("\(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language) · \(OnScreenTextSettings.qualityLabel(voice))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if voiceID == id { Image(systemName: "checkmark") }
            }
        }
        .accessibilityHint("Selects this voice and plays a sample")
    }

    private func speakSample(_ voice: AVSpeechSynthesisVoice?) {
        preview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Turns out, this van is bulletproof.")
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        preview.speak(utterance)
    }
}
