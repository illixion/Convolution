/*
 Hypnos - Remote Viewer Ornament View

 Control bar for the slideshow window.
 [ Grid | Prev | Next | 3D | Resolution | Adjustments | Profile ]
 */

import RAVEUI
import SwiftUI

struct RemoteViewerOrnamentView: View {
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow
    @Bindable var model: RemoteViewerModel

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

            // 3D Mode Menu
            if PlatformCapabilities.supportsSpatial3D {
                slideshow3DMenu
            }

            // Max Image Resolution Menu (per current mode: 2D or 3D)
            resolutionMenu

            // Visual Adjustments
            adjustmentsButton

            Divider()
                .frame(height: 24)

            identityLabel
        }
        .padding(.horizontal, RAVEChromeMetrics.horizontalPadding)
        .padding(.vertical, RAVEChromeMetrics.verticalPadding)
        .glassBackgroundEffect()
    }

    /// Which slideshow this is (pictures or videos), matching what the window
    /// group's tile shows for the same profile.
    private var identityLabel: some View {
        Text(model.config.name)
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
            .help("Slideshow profile")
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
                    // AI 3D runs the real-time depth model, pictures and
                    // videos alike.
                    .disabled(mode == .aiDepth && !ThumbnailDepthEstimator.shared.isModelAvailable)
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
        .help("Slideshow 3D: \(model.config.slideshow3DMode.shortLabel)")
    }

    private func applySlideshow3DMode(_ mode: Slideshow3DMode) {
        var updated = model.config
        updated.slideshow3DMode = mode
        model.config = updated
        model.slideshow3DMode = mode
        model.onConfigChanged?(updated)
    }

    private var resolutionMenu: some View {
        // AI 3D textures its mesh from the 2D-sized picture.
        let is3D = model.config.slideshow3DMode.usesRealityKit
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
