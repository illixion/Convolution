import SwiftUI

extension View {
    /// Makes the space around a text field focus it when tapped.
    ///
    /// A `TextField`/`SecureField` is only as tall as its text, while the Form
    /// row or bordered shell drawn around it is much taller. That padding takes
    /// no input, so on visionOS a pinch while looking slightly above or below
    /// the text (a miscalibrated gaze, or simply a small target) does nothing.
    /// This puts a tap target behind the field that reaches `outset` points
    /// past its top and bottom edges and focuses the field. Taps on the field
    /// itself still land on the field (it is in front), so cursor placement is
    /// unaffected. On visionOS the target also highlights under gaze, so the
    /// user can see the shell is aimable.
    ///
    /// No-op on tvOS (focus engine, no taps) and macOS (a precise pointer).
    func textFieldTapTarget(outset: CGFloat = 10) -> some View {
        modifier(TextFieldTapTarget(outset: outset))
    }
}

private struct TextFieldTapTarget: ViewModifier {
    let outset: CGFloat
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        #if os(visionOS) || os(iOS)
        content
            .focused($isFocused)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    #if os(visionOS)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))
                    .hoverEffect(.highlight)
                    #endif
                    .onTapGesture { isFocused = true }
                    // Negative padding grows the target past the field's own
                    // frame, into the row padding, without changing layout.
                    .padding(.vertical, -outset)
            }
        #else
        content
        #endif
    }
}
