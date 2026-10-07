/*
 Hypnos - Video Adjustments Window

 A standalone, freely-repositionable window hosting the Adjustments controls for
 the active video window. Kept separate (rather than an ornament/popover) so it
 never overlaps or is occluded by the front-plane fake-3D video — the user can
 drag it wherever they like and watch edits apply live.

 It edits the shared `VideoWindowModel` referenced by
 `AppModel.videoAdjustmentsTarget`, so changes propagate to the video window in
 real time (same @Observable instance).
 */

import RAVEMedia
import SwiftUI

struct VideoAdjustmentsWindowView: View {
    @Environment(AppModel.self) private var appModel
    @DismissWindowProxy private var dismissWindow

    var body: some View {
        Group {
            if let target = appModel.videoAdjustmentsTarget {
                let bindable = Bindable(target)
                VStack(spacing: 0) {
                    VisualAdjustmentsPopover(
                        currentAdjustments: bindable.currentAdjustments,
                        globalAdjustments: Binding(
                            get: { appModel.globalVisualAdjustments },
                            set: { appModel.globalVisualAdjustments = $0 }
                        ),
                        showAutoEnhance: false,
                        showFlip: true,
                        isImageFlipped: target.isFlipped,
                        onToggleFlip: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                target.toggleFlip()
                            }
                        },
                        // Fake-3D only: live stereo separation / convergence
                        // (Current = per-window override, Global = default for
                        // other fake-3D videos).
                        pseudo3DSettings: target.shouldUsePseudo3D ? bindable.pseudo3DSettings : nil,
                        globalPseudo3DSettings: target.shouldUsePseudo3D ? Binding(
                            get: { appModel.globalPseudo3DSettings },
                            set: { appModel.globalPseudo3DSettings = $0 }
                        ) : nil
                    )
                    .padding(20)
                    if target.subtitles.selected != nil {
                        SubtitleDelayControl(controller: target.subtitles)
                            .padding([.horizontal, .bottom], 20)
                    }
                }
                .frame(minWidth: 340)
                .navigationTitle(target.videoDisplayName)
            } else {
                // Target went away (video window closed) — dismiss ourselves.
                Color.clear
                    .onAppear { dismissWindow() }
            }
        }
        .onDisappear {
            appModel.videoAdjustmentsTarget?.showAdjustments = false
            appModel.videoAdjustmentsTarget = nil
        }
    }
}
