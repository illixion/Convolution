/*
 Hypnos - transparent, fixed web views

 The web views that play a picture or a video (animated images, the WebKit
 video player) show only their page's one element: no background of their
 own, no scrolling. UIKit's WKWebView says so through its view and scroll
 view; macOS's has neither property, and its `drawsBackground` (the switch
 AppKit's web views have always had) is reachable only by key.
 */

#if canImport(WebKit)
import WebKit

extension WKWebView {
    /// Clear where the page draws nothing, and not scrollable.
    func makeTransparentAndFixed() {
        #if os(macOS)
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        #else
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = false
        #endif
    }
}
#endif
