/*
 Hypnos - Remote Viewer Ornament View

 Control bar for the Remote API Viewer window.
 [ Grid | History | Prev | Next | Save | Home | Tag List | Mod Tags | Sync | Adjustments | Block ]
 */

import RAVEUI
import SwiftUI

struct RemoteViewerOrnamentView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @Bindable var model: RemoteViewerModel
    var tagListManager: TagListManager
    var modTagManager: ModTagManager
    @Binding var showHistory: Bool

    /// Local UI state for the in-ornament "Add Preset…" popover. Lives here
    /// rather than on the model since it's view-only and tied to this
    /// window's ornament.
    @State private var showAddPresetPopover = false
    @State private var newPresetText = ""

    var body: some View {
        HStack(spacing: RAVEChromeMetrics.spacing) {
            // Grid - Open main app window
            Button {
                appModel.showMainWindow(openWindow: openWindow)
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .raveChromeButtonStyle()
            .help("Open Gallery")

            // History
            Button {
                withAnimation { showHistory.toggle() }
            } label: {
                Image(systemName: showHistory ? "clock.arrow.circlepath" : "clock.arrow.circlepath")
                    .font(.title3)
                    .padding(6)
                    .background(showHistory ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
            }
            .raveChromeButtonStyle()
            .help("View History")

            Divider()
                .frame(height: 24)

            // Previous
            Button {
                model.previousImage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .raveChromeButtonStyle()
            .disabled(model.postHistory.count < 2)
            .help("Previous Image")

            // Next
            Button {
                model.advanceToNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .raveChromeButtonStyle()
            .help("Next Image")

            Divider()
                .frame(height: 24)

            if !model.isGalleryMode {
                // Save (API mode only)
                Button {
                    model.saveCurrentPost()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                }
                .raveChromeButtonStyle()
                .disabled(model.saveablePost == nil)
                .help("Save Image")

                // Reshuffle - ask the server to reshuffle post order
                Button {
                    model.reshuffle()
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.title3)
                }
                .raveChromeButtonStyle()
                .help("Reshuffle")

                // Tag List Selector
                tagListMenu

                // Mod Tag Preset Selector
                modTagMenu

                // Display Sync Toggle
                Button {
                    model.enableDisplaySync.toggle()
                } label: {
                    Image(systemName: model.enableDisplaySync ? "link.circle.fill" : "link.circle")
                        .font(.title3)
                        .padding(6)
                        .background(model.enableDisplaySync ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
                }
                .raveChromeButtonStyle()
                .help(model.enableDisplaySync ? "Display Sync On" : "Display Sync Off")
            }

            // 3D Mode Menu
            if PlatformCapabilities.supportsSpatial3D {
                slideshow3DMenu
            }

            // Max Image Resolution Menu (per current mode: 2D or 3D)
            resolutionMenu

            // Visual Adjustments
            adjustmentsButton

            if !model.isGalleryMode {
                // Block (API mode only)
                Button {
                    model.blockCurrentPost()
                } label: {
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .raveChromeButtonStyle()
                .disabled(model.currentPost == nil)
                .help("Block Post")
            }

            Divider()
                .frame(height: 24)

            identityLabel
        }
        .padding(.horizontal, RAVEChromeMetrics.horizontalPadding)
        .padding(.vertical, RAVEChromeMetrics.verticalPadding)
        .glassBackgroundEffect()
    }

    /// Which viewer this is. Slideshow windows are otherwise indistinguishable
    /// from each other — same chrome, content that changes every few seconds — so
    /// restoring several from a saved window group left no way to tell which
    /// window is which. The profile name plus its RoboFrame device id (or the
    /// endpoint host when the profile has no device id) is that identity, and it
    /// matches what the window group's tile shows for the same profile.
    private var identityLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.config.name)
                .font(.callout)
                .lineLimit(1)
            if let detail = AppModel.remoteIdentityDetail(for: model.config) {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help("Profile and display id for this viewer")
    }

    private var tagListMenu: some View {
        Menu {
            Group {
                ForEach(tagListManager.tagLists.indices, id: \.self) { index in
                    Button {
                        tagListManager.switchToTagList(index)
                    } label: {
                        HStack {
                            Text(tagListLabel(index))
                            if tagListManager.activeIndex == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.title3)
                Text("\(tagListManager.activeIndex + 1)/\(tagListManager.tagLists.count)")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .disabled(tagListManager.tagLists.count <= 1)
        .help("Tag List")
    }

    private func tagListLabel(_ index: Int) -> String {
        let tags = tagListManager.tagLists[index]
        let firstTag = tags.first ?? ""
        return "List \(index + 1): \(firstTag)"
    }

    private var modTagMenu: some View {
        Menu {
            Group {
                // "None" sentinel for clearing any active preset.
                Button {
                    modTagManager.clearActive()
                } label: {
                    HStack {
                        Text("None")
                        if modTagManager.activeIndex == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                ForEach(modTagManager.modTagLists.indices, id: \.self) { index in
                    Button {
                        modTagManager.switchToPreset(index)
                    } label: {
                        HStack {
                            Text(modTagLabel(index))
                            if modTagManager.activeIndex == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    newPresetText = ""
                    showAddPresetPopover = true
                } label: {
                    Label("Add Preset…", systemImage: "plus")
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.title3)
                Text(modTagBadge)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .help("Mod Tags")
        .popover(isPresented: $showAddPresetPopover) {
            addPresetPopover
        }
    }

    private var addPresetPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Mod Tag Preset")
                .font(.headline)
            Text("Space-separated tags. Negate with a leading `-`.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("rating:s -blood", text: $newPresetText)
                .textFieldTapTarget()
                .roundedTextFieldStyle()
                .font(.body.monospaced())
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .frame(minWidth: 320)
                .onSubmit { commitNewPreset() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showAddPresetPopover = false
                }
                Button("Add & Apply") { commitNewPreset() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedNewPresetTags.isEmpty)
            }
        }
        .padding(20)
        .onAppear { updateOrnamentMenuCount(opened: true) }
        .onDisappear { updateOrnamentMenuCount(opened: false) }
    }

    private var parsedNewPresetTags: [String] {
        newPresetText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func commitNewPreset() {
        let tags = parsedNewPresetTags
        guard !tags.isEmpty else { return }
        var lists = modTagManager.modTagLists
        lists.append(tags)
        modTagManager.modTagLists = lists
        // Switch to the freshly added preset so it takes effect immediately —
        // matches the "tap the menu, see the slideshow react" expectation.
        modTagManager.switchToPreset(lists.count - 1)
        newPresetText = ""
        showAddPresetPopover = false
    }

    private func modTagLabel(_ index: Int) -> String {
        let tags = modTagManager.modTagLists[index]
        let firstTag = tags.first ?? ""
        return "Preset \(index + 1): \(firstTag)"
    }

    private var modTagBadge: String {
        guard let idx = modTagManager.activeIndex else { return "—" }
        return "\(idx + 1)/\(modTagManager.modTagLists.count)"
    }

    private var adjustmentsButton: some View {
        @Bindable var appModel = appModel

        return Button {
            model.showAdjustmentsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .padding(6)
                .background(
                    (model.currentAdjustments.isModified || appModel.globalVisualAdjustments.isModified)
                        ? .white.opacity(0.3) : .clear,
                    in: .rect(cornerRadius: 8)
                )
        }
        .raveChromeButtonStyle()
        .help("Visual Adjustments")
        .popover(isPresented: $model.showAdjustmentsPopover) {
            VisualAdjustmentsPopover(
                currentAdjustments: $model.currentAdjustments,
                globalAdjustments: $appModel.globalVisualAdjustments,
                showAutoEnhance: false,
                remoteViewerModel: model
            )
        }
    }

    private var slideshow3DMenu: some View {
        Menu {
            Group {
                ForEach(Slideshow3DMode.allCases) { mode in
                    Button {
                        applySlideshow3DMode(mode)
                    } label: {
                        HStack {
                            Text(mode.label)
                            if model.config.slideshow3DMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            Image(systemName: model.config.slideshow3DMode.systemImage)
                .font(.title3)
                .padding(6)
                .background(model.config.slideshow3DMode != .off ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .help("Slideshow 3D Mode")
    }

    private func applySlideshow3DMode(_ mode: Slideshow3DMode) {
        var updated = model.config
        updated.slideshow3DMode = mode
        model.config = updated
        model.slideshow3DMode = mode
        model.onConfigChanged?(updated)
    }

    private var resolutionMenu: some View {
        let is3D = model.config.slideshow3DMode != .off
        let currentValue: Int = is3D
            ? (model.config.maxImageResolution3D ?? appModel.slideshowMaxImageResolution3D)
            : (model.config.maxImageResolution2D ?? appModel.slideshowMaxImageResolution2D)
        let currentLabel = AppModel.maxImageResolutionOptions.first(where: { $0.value == currentValue })?.label ?? "Off"

        return Menu {
            Group {
                ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                    Button {
                        applyResolution(option.value, is3D: is3D)
                    } label: {
                        HStack {
                            Text(option.label)
                            if option.value == currentValue {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .onAppear { updateOrnamentMenuCount(opened: true) }
            .onDisappear { updateOrnamentMenuCount(opened: false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.title3)
                Text(currentLabel)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.button)
        .raveChromeButtonStyle()
        .help(is3D ? "Max Image Resolution (3D)" : "Max Image Resolution (2D)")
    }

    private func applyResolution(_ value: Int, is3D: Bool) {
        var updated = model.config
        if is3D {
            updated.maxImageResolution3D = value
            model.maxImageResolution3D = value
        } else {
            updated.maxImageResolution2D = value
            model.maxImageResolution = value
        }
        model.config = updated
        model.onConfigChanged?(updated)
    }

    /// Increment / decrement the model's open-menu counter. Clamped at zero
    /// so a missed event can't drive the count negative. Used by the window
    /// view to suppress the diorama foreground while a menu is shown.
    private func updateOrnamentMenuCount(opened: Bool) {
        if opened {
            model.openOrnamentMenuCount += 1
        } else {
            model.openOrnamentMenuCount = max(0, model.openOrnamentMenuCount - 1)
        }
    }
}
