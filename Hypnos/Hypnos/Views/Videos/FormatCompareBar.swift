/*
 Hypnos - comparing a VR video's likely formats

 Under the window, in the prompt's place (where Skip Intro goes): one big
 button per reading the picture could be (Fisheye 180°, Fisheye 190°,
 Flat 180°…), the one showing filled. A tap shows that reading at once, on
 the sphere around the viewer, so two can be flipped between like an A/B
 test; Swap Eyes does the same for the eye order; Keep closes the bar with
 the one showing. `VideoWindowModel.formatCompare` holds the readings.
 */

import SwiftUI
import VergenceApple

struct FormatCompareBar: View {
    let candidates: [FormatCandidate]
    let shown: VRFormat
    let pick: (FormatCandidate) -> Void
    let swapEyes: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(candidates) { candidate in
                let isShown = candidate.matches(shown)
                Button { pick(candidate) } label: {
                    Text(candidate.title)
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .modifier(CompareButtonStyle(prominent: isShown))
                .accessibilityAddTraits(isShown ? .isSelected : [])
            }
            if shown.layout != nil {
                Button(action: swapEyes) {
                    Label("Swap Eyes", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .modifier(CompareButtonStyle(prominent: shown.layout?.eyesReversed == true))
            }
            Button(action: done) {
                Label("Keep", systemImage: "checkmark")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .modifier(CompareButtonStyle(prominent: false))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityIdentifier("player.formatCompare")
    }
}

private struct CompareButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        Group {
            if prominent {
                #if os(visionOS) || os(tvOS)
                content.buttonStyle(.borderedProminent)
                #else
                content.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                #endif
            } else {
                content.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}
