/*
 Hypnos - tvOS slideshow button

 Above the Pictures and Videos grids and in a Local folder: starts the app's
 slideshow of what is shown (`TVSlideshowView`). Play/Pause on the grid does
 the same.
 */

#if os(tvOS)

import SwiftUI

struct TVSlideshowButton: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Label("Play Slideshow", systemImage: "play.fill")
            }
            Spacer(minLength: 0)
        }
        // The whole row is a focus section, so moving down from anywhere
        // along the tab bar (or up from any cell of the first row) lands on
        // the button, not only from straight above or below it.
        .focusSection()
    }
}

#endif
