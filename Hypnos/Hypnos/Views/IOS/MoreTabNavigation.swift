/*
 Hypnos - iPhone: tabs that live under More and bring their own navigation

 On a compact iPhone the tabs past the fifth go into More, which is a
 UINavigationController of its own. A tab whose content has its own
 `NavigationStack` (Settings, Filters, Library, YouTube) then shows two
 navigation bars, More's above the tab's, once anything is pushed: a known
 SwiftUI limitation with no API to opt out (Apple developer forums thread
 764293).

 `ownsNavigationInMoreTab()` (on the tab page, outside its stack) hides
 More's bar while the tab is on screen and puts it back when the tab goes
 away, so More's own list keeps its title and Edit button.
 `moreTabBackButton()` (on the stack's root page) then puts the missing way
 back to the More list in the tab's own bar. Both do nothing outside More,
 and nothing on other platforms.
 */

import SwiftUI

extension View {
    func ownsNavigationInMoreTab() -> some View {
        #if os(iOS)
        modifier(MoreTabNavigationOwner())
        #else
        self
        #endif
    }

    func moreTabBackButton() -> some View {
        #if os(iOS)
        modifier(MoreTabBackButton())
        #else
        self
        #endif
    }
}

#if os(iOS)

import UIKit

/// The More navigation controller a tab is shown in, if it is.
@MainActor
@Observable
private final class MoreTabNavigation {
    weak var controller: UINavigationController?
}

private extension EnvironmentValues {
    @Entry var moreTabNavigation: MoreTabNavigation?
}

private struct MoreTabNavigationOwner: ViewModifier {
    @State private var navigation = MoreTabNavigation()

    func body(content: Content) -> some View {
        content
            .background(MoreNavigationProbe(navigation: navigation).frame(width: 0, height: 0))
            .environment(\.moreTabNavigation, navigation)
    }
}

private struct MoreTabBackButton: ViewModifier {
    @Environment(\.moreTabNavigation) private var navigation

    func body(content: Content) -> some View {
        content.toolbar {
            if let controller = navigation?.controller {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.popToRootViewController(animated: true)
                    } label: {
                        Label("More", systemImage: "chevron.backward")
                    }
                }
            }
        }
    }
}

/// A zero-size child view controller, there only to find the More
/// navigation controller among its ancestors as the tab appears.
private struct MoreNavigationProbe: UIViewControllerRepresentable {
    let navigation: MoreTabNavigation

    func makeUIViewController(context: Context) -> Probe {
        Probe(navigation: navigation)
    }

    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        private let navigation: MoreTabNavigation

        init(navigation: MoreTabNavigation) {
            self.navigation = navigation
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let more = enclosingMoreController()
            more?.setNavigationBarHidden(true, animated: animated)
            navigation.controller = more
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigation.controller?.setNavigationBarHidden(false, animated: animated)
        }

        private func enclosingMoreController() -> UINavigationController? {
            var current = parent
            while let controller = current {
                if let nav = controller as? UINavigationController,
                   let tabs = nav.tabBarController, nav === tabs.moreNavigationController {
                    return nav
                }
                current = controller.parent
            }
            return nil
        }
    }
}

#endif
