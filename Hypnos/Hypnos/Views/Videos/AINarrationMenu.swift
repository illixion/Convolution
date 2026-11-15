import OnScreenText
import RAVEUI
import SwiftUI

/// AI Narration in the control strip, beside Audio and the equalizer: an effect
/// on the video's sound, not a subtitle track. It reads the words written on
/// the picture (burned-in subtitles) a few seconds ahead and speaks them in the
/// voice chosen in Settings → AI Features → AI Narration, lowering the video's
/// sound while it speaks. Shown for the players that can read their picture.
struct AINarrationMenu: View {
    let controller: SubtitleController
    var onOpenChanged: (Bool) -> Void = { _ in }
    @AppStorage(OnScreenTextSettings.areaKey, store: HypnosDefaults.store) private var area = OnScreenTextSettings.Area.bottom.rawValue

    var body: some View {
        let reader = controller.onScreen
        PlayerChoiceMenu(title: "AI Narration", systemImage: "waveform.badge.mic",
                         badge: reader.enabled ? "AI" : nil, badgeIsActive: true,
                         help: reader.enabled ? "AI Narration is on" : "AI Narration",
                         onOpenChanged: onOpenChanged) { close in
            Toggle(isOn: Binding(get: { reader.enabled }, set: { _ in controller.toggleAINarration() })) {
                Label("AI Narration", systemImage: "waveform.badge.mic")
            }
            .accessibilityIdentifier("player.aiNarration.toggle")
            Text("Speaks the words written on the picture.")
                .font(.caption).foregroundStyle(.secondary)
            if reader.enabled {
                if reader.status != "On-Screen Text" {
                    HStack(spacing: 8) {
                        if !reader.isBuffering { ProgressView().controlSize(.small) }
                        Text(reader.status).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if reader.isBuffering {
                    ProgressView(value: reader.lookaheadProgress)
                        .accessibilityLabel("Picture read ahead")
                    Text(String(format: "%.1f seconds read ahead", reader.readAheadSeconds))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if controller.isMutedForNarration {
                    Text("The video is muted, so nothing is spoken.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(OnScreenTextSettings.Area.allCases.filter { $0 != .custom || area == $0.rawValue }) { choice in
                    Button {
                        area = choice.rawValue
                        reader.region = OnScreenTextSettings.region
                    } label: {
                        PlayerChoiceRow("Read: \(choice.title)", isChecked: area == choice.rawValue)
                    }
                }
            }
            if let error = reader.error {
                Text(error).font(.caption)
            }
        }
        .accessibilityIdentifier("player.aiNarration")
    }
}
