/*
 Hypnos - Settings → On-Screen Text

 Narration of burned-in subtitles: on or off, the voice (Kokoro's neural
 voices once downloaded; the system's installed voices, best first; Personal
 Voice once allowed), how fast, and
 where in the picture to read. Every platform; tvOS has no Slider, so its
 speed is stepped and it has no custom area.
 */

import AVFoundation
import OnScreenText
import SwiftUI

struct OnScreenTextSettingsPage: View {
    @AppStorage(OnScreenTextSettings.voiceKey, store: HypnosDefaults.store) private var voiceID = ""
    @AppStorage(OnScreenTextSettings.rateKey, store: HypnosDefaults.store) private var rate = 1.0
    @AppStorage(OnScreenTextSettings.areaKey, store: HypnosDefaults.store) private var area = OnScreenTextSettings.Area.bottom.rawValue
    @AppStorage(OnScreenTextSettings.customTopKey, store: HypnosDefaults.store) private var customTop = 0.55
    @AppStorage(OnScreenTextSettings.customBottomKey, store: HypnosDefaults.store) private var customBottom = 1.0
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var preview = AVSpeechSynthesizer()
    @State private var kokoroDownloaded = OnScreenTextKokoro.isDownloaded
    @State private var kokoroBusy = false
    @State private var kokoroError: String?
    @State private var kokoroSize: Int64 = 0
    @AppStorage(OnScreenTextSettings.availableKey, store: HypnosDefaults.store) private var available = false
    @State private var kokoroSample = KokoroSamplePlayer()

    var body: some View {
        SettingsPage("AI Narration") {
            Section {
                Toggle("Offer AI Narration", isOn: $available)
            } header: {
                Text("Availability")
            } footer: {
                Text("""
                Some videos, such as narration-free YouTube channels and game footage with a creator's captions, write                 their words on the picture instead of saying them. AI Narration reads that text off the picture on this                 device, a few seconds ahead of the video, and speaks it aloud in the voice chosen below, lowering the                 video's own sound while it talks. The picture is never sent anywhere, and no subtitle track is made or                 changed. It works with the system voices and, if you download them, Kokoro's natural-sounding ones.

                This switch only adds an AI Narration button to a video's controls.                 It never starts by itself: you turn it on, per video, from that menu. Reading ahead costs some battery                 and heat, and the video waits briefly at the start while the first words are read.
                """)
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

            kokoroSection

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
        .task {
            voices = OnScreenTextSettings.voices()
            if kokoroDownloaded { kokoroSize = OnScreenTextKokoro.diskSize() }
        }
        .onDisappear { kokoroSample.stop() }
    }

    @ViewBuilder
    private var kokoroSection: some View {
        Section {
            if kokoroDownloaded {
                ForEach(OnScreenTextKokoro.voices) { kokoroRow($0) }
                Button("Remove Kokoro Voices", role: .destructive) { removeKokoro() }
                    .disabled(kokoroBusy)
            } else if kokoroBusy {
                HStack {
                    ProgressView()
                    Text("Downloading and preparing Kokoro…").foregroundStyle(.secondary)
                }
            } else {
                Button("Download Kokoro Voices") { downloadKokoro() }
            }
            if let kokoroError {
                Text(kokoroError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Kokoro Voices")
        } footer: {
            Text(kokoroDownloaded
                 ? "Natural-sounding English voices that run on this device. They use \(ByteCountFormatter.string(fromByteCount: kokoroSize, countStyle: .file)) of storage."
                 : "Natural-sounding English voices that run on this device. About 100 MB, downloaded once from Hugging Face; preparing them the first time takes up to a minute.")
        }
    }

    private func kokoroRow(_ voice: OnScreenTextKokoro.Voice) -> some View {
        Button {
            voiceID = voice.identifier
            preview.stopSpeaking(at: .immediate)
            kokoroSample.play(voice: voice.id, rate: Float(rate))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name).foregroundStyle(.primary)
                    Text("\(voice.detail) · Kokoro").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if voiceID == voice.identifier { Image(systemName: "checkmark") }
            }
        }
        .accessibilityHint("Selects this voice and plays a sample")
    }

    private func downloadKokoro() {
        kokoroBusy = true
        kokoroError = nil
        Task {
            OnScreenTextKokoro.shared.retain()
            defer { OnScreenTextKokoro.shared.release() }
            do {
                try await OnScreenTextKokoro.shared.prepare()
                kokoroDownloaded = true
                kokoroSize = OnScreenTextKokoro.diskSize()
            } catch {
                kokoroError = "Couldn't download Kokoro: \(error.localizedDescription)"
            }
            kokoroBusy = false
        }
    }

    private func removeKokoro() {
        kokoroSample.stop()
        if OnScreenTextKokoro.voice(forIdentifier: voiceID) != nil { voiceID = "" }
        kokoroBusy = true
        Task {
            try? await OnScreenTextKokoro.shared.remove()
            kokoroDownloaded = OnScreenTextKokoro.isDownloaded
            kokoroBusy = false
        }
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
        kokoroSample.stop()
        preview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Turns out, this van is bulletproof.")
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        preview.speak(utterance)
    }
}

/// Plays a Kokoro sample in Settings; the models are loaded for it and
/// released again when the page closes.
@MainActor
private final class KokoroSamplePlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var task: Task<Void, Never>?
    private var retained = false

    func play(voice: String, rate: Float) {
        stopPlayback()
        if !retained { retained = true; OnScreenTextKokoro.shared.retain() }
        task = Task {
            guard let buffer = try? await OnScreenTextKokoro.shared.synthesize(
                "Turns out, this van is bulletproof.", voice: voice, speed: rate), !Task.isCancelled else { return }
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            guard (try? engine.start()) != nil else { return }
            node.scheduleBuffer(buffer, completionHandler: nil)
            node.play()
            self.engine = engine
            self.node = node
        }
    }

    private func stopPlayback() {
        task?.cancel()
        node?.stop()
        engine?.stop()
        engine = nil; node = nil
    }

    func stop() {
        stopPlayback()
        if retained { retained = false; OnScreenTextKokoro.shared.release() }
    }
}
