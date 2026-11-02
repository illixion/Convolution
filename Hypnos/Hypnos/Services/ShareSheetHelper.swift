/*
 Hypnos - Share Sheet Helper

 SwiftUI wrapper for UIActivityViewController on visionOS.
 Presented via SwiftUI's .sheet to ensure proper hand tracking input.
 */

import DebugTrace
import SwiftUI

// UIActivityViewController (the share sheet) doesn't exist on tvOS — there's
// no AirDrop/Files/Messages target for a Siri Remote UX to hand a file to.
// The Share button is hidden from the tvOS ornaments at each call site.
// macOS shares through `NSSharingServicePicker`, shown from the button.

extension View {
    /// The system's share options for `url` while it is set; cleared, and
    /// `onDismiss` called, once they close. A sheet with the activity view on
    /// iOS and visionOS, the sharing picker next to this view on macOS.
    func shareSheet(url: Binding<URL?>, onDismiss: @escaping () -> Void = {}) -> some View {
        #if os(macOS)
        background(SharingPickerAnchor(url: url, onDismiss: onDismiss))
        #elseif os(tvOS)
        self
        #else
        sheet(isPresented: Binding(
            get: { url.wrappedValue != nil },
            set: { if !$0 { url.wrappedValue = nil } }
        ), onDismiss: onDismiss) {
            if let shared = url.wrappedValue {
                ActivityViewController(
                    activityItems: [shared],
                    isPresented: Binding(
                        get: { url.wrappedValue != nil },
                        set: { if !$0 { url.wrappedValue = nil } }
                    )
                )
            }
        }
        #endif
    }
}

#if os(macOS)
/// Shows the sharing picker below the view it backs whenever `url` is set.
private struct SharingPickerAnchor: NSViewRepresentable {
    @Binding var url: URL?
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.close = {
            url = nil
            onDismiss()
        }
        guard let url, context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        // After this update: the picker runs its own event loop.
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = context.coordinator
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var shown: URL?
        var close: () -> Void = {}

        /// Called with nil when the picker closes without a choice too.
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            shown = nil
            close()
        }
    }
}
#endif

#if !os(tvOS) && !os(macOS)
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> ActivityHostController {
        ActivityHostController(activityItems: activityItems, isPresented: $isPresented)
    }

    func updateUIViewController(_ uiViewController: ActivityHostController, context: Context) {}
}

/// Container that presents UIActivityViewController in viewDidAppear,
/// ensuring the view is fully in the hierarchy before presentation.
class ActivityHostController: UIViewController {
    private let activityItems: [Any]
    private var isPresented: Binding<Bool>
    private var didPresent = false

    init(activityItems: [Any], isPresented: Binding<Bool>) {
        self.activityItems = activityItems
        self.isPresented = isPresented
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true

        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            DispatchQueue.main.async {
                self?.isPresented.wrappedValue = false
            }
        }
        present(activityVC, animated: true)
    }
}
#endif

@MainActor
enum ShareSheetHelper {
    /// Prepare a shareable file URL with a human-readable name and correct extension.
    ///
    /// The file is a *copy* (an APFS clone, so no extra disk space) in a folder
    /// of its own, never a hardlink to the cache entry. A hardlink shares the
    /// cache file's inode, whose own name is a bare hash with no extension;
    /// the system's share sheet resolves a file by identity as well as by path,
    /// found no type for it, and listed the item with every action dead
    /// ("is not shareable by client", Launch Services -10814). A folder per
    /// share also means preparing the same image again cannot delete the file
    /// a sheet still open from the last share is holding.
    static func prepareShareFile(from sourceURL: URL, title: String?, originalURL: URL) -> URL {
        let fm = FileManager.default
        let shareRoot = fm.temporaryDirectory.appendingPathComponent("ShareItems", isDirectory: true)
        removeStaleShares(in: shareRoot)

        let fileName = shareFileName(title: title, originalURL: originalURL, sourceURL: sourceURL)
        let destDir = shareRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destURL = destDir.appendingPathComponent(fileName)

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            // Share the original rather than a path with nothing behind it.
            AppLogger.photoWindow.error("Could not stage the share file: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return sourceURL
        }

        let size = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? -1
        AppLogger.photoWindow.info("Share file ready: ext=\(destURL.pathExtension.lowercased(), privacy: .public) bytes=\(size, privacy: .public)")
        return destURL
    }

    /// A file name safe to hand to the share sheet: no path separators or
    /// control characters, a bounded length, and an extension whenever one is
    /// known (the title's own, else the original URL's, else the source's).
    private static func shareFileName(title: String?, originalURL: URL, sourceURL: URL) -> String {
        var name = (title?.isEmpty == false ? title! : originalURL.lastPathComponent)
        name = name.unicodeScalars
            .map { "/:\\".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "image" }

        if (name as NSString).pathExtension.isEmpty {
            let ext = [originalURL, sourceURL].map(\.pathExtension).first { !$0.isEmpty } ?? ""
            if !ext.isEmpty { name += ".\(ext)" }
        }
        // 255 bytes is the file system's limit; keep the extension when cutting.
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = String((name as NSString).deletingPathExtension.prefix(150))
            name = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return name
    }

    /// Shares older than a day are no longer open in any sheet.
    private static func removeStaleShares(in root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: entry) }
        }
    }
}
