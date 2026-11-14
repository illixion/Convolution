//
//  PhotoSleeveRemote.swift
//  Hypnos
//
//  What the forearm remote (`ForearmSleeve`) shows while a photo is in the viewer HUD: the
//  picture's name and place, previous / next, the chrome and Return to Window, the 3D modes, and a
//  second page of adjustments. The HUD lives in an immersive space, where visionOS presents no
//  popovers, so the window's Adjustments popover can't open there (device, 2026-11-14); the
//  sleeve is the HUD's way to them.
//
//  Every press makes the same model call the window's own controls make (the 3D menu's
//  `toggleRealityKit3D` / `showFlat` / `toggleAIDepth`, the Adjustments popover's slider curve and
//  commit).
//

#if os(visionOS)

import QuartzCore
import RAVEPanel
import RealityKit
import SwiftUI

@MainActor
final class PhotoSleeveRemote: SleeveRemote {
    enum Tile {
        static let title = "photo.title"
        static let previous = "photo.previous"
        static let chrome = "photo.chrome"
        static let window = "photo.window"
        static let next = "photo.next"
        static let flat = "photo.mode.2d"
        static let realityKit = "photo.mode.rk"
        static let immersive = "photo.mode.immersive"
        static let aiDepth = "photo.mode.ai"
        static let adjust = "photo.adjust"
        static let brightness = "photo.brightness"
        static let contrast = "photo.contrast"
        static let saturation = "photo.saturation"
        static let opacity = "photo.opacity"
        static let reset = "photo.reset"
        static let back = "photo.back"
    }

    private enum Action {
        static let previous = "photo.previous"
        static let next = "photo.next"
        static let chrome = "photo.chrome"
        static let window = "photo.window"
        static let flat = "photo.mode.2d"
        static let realityKit = "photo.mode.rk"
        static let immersive = "photo.mode.immersive"
        static let aiDepth = "photo.mode.ai"
        static let adjustment = "photo.adjustment"
        static let reset = "photo.reset"
    }

    /// An adjustment slider: what it sets, over the popover's range and default.
    private struct Slider {
        let tile: String
        let label: String
        let range: ClosedRange<Double>
        let defaultValue: Double
        /// Linear like the popover's Opacity, else its curve.
        let linear: Bool
        let keyPath: WritableKeyPath<VisualAdjustments, Double>
    }

    private static let sliders = [
        Slider(tile: Tile.brightness, label: "Brightness", range: -0.5...0.5, defaultValue: 0, linear: false, keyPath: \.brightness),
        Slider(tile: Tile.contrast, label: "Contrast", range: 0.2...5.0, defaultValue: 1, linear: false, keyPath: \.contrast),
        Slider(tile: Tile.saturation, label: "Saturation", range: 0.0...5.0, defaultValue: 1, linear: false, keyPath: \.saturation),
        Slider(tile: Tile.opacity, label: "Opacity", range: 0.01...1.0, defaultValue: 1, linear: true, keyPath: \.opacity),
    ]

    static let layout = RAVESleeveLayout(outer: [
        RAVESleevePage("photo", title: "Photo", rows: [
            [RAVESleeveTile(Tile.title, .label, span: 4)],
            [
                RAVESleeveTile(Tile.previous, .button(RAVESleeveAction(Action.previous)), label: "Previous", icon: "chevron.backward"),
                RAVESleeveTile(Tile.chrome, .toggle(RAVESleeveAction(Action.chrome)), label: "Controls", icon: "slider.horizontal.below.rectangle"),
                RAVESleeveTile(Tile.window, .button(RAVESleeveAction(Action.window)), label: "Window", icon: "rectangle.on.rectangle"),
                RAVESleeveTile(Tile.next, .button(RAVESleeveAction(Action.next)), label: "Next", icon: "chevron.forward", role: .primary),
            ],
            [
                RAVESleeveTile(Tile.flat, .button(RAVESleeveAction(Action.flat)), label: "2D", icon: "rectangle"),
                RAVESleeveTile(Tile.realityKit, .button(RAVESleeveAction(Action.realityKit)), label: "RK 3D", icon: "spatial.capture.fill"),
                RAVESleeveTile(Tile.immersive, .button(RAVESleeveAction(Action.immersive)), label: "Immersive", icon: "inset.filled.pano"),
                RAVESleeveTile(Tile.aiDepth, .button(RAVESleeveAction(Action.aiDepth)), label: "AI 3D", icon: "wand.and.sparkles"),
            ],
            [RAVESleeveTile(Tile.adjust, .page("photo.adjust"), label: "Adjust", icon: "slider.horizontal.3", span: 4)],
        ]),
        RAVESleevePage("photo.adjust", title: "Adjust", rows: sliders.map { slider in
            [RAVESleeveTile(slider.tile, .slider(RAVESleeveAction(Action.adjustment, argument: slider.tile)),
                            label: slider.label, span: 4)]
        } + [[
            RAVESleeveTile(Tile.reset, .button(RAVESleeveAction(Action.reset)), label: "Reset", icon: "arrow.counterclockwise", span: 2),
            RAVESleeveTile(Tile.back, .page("photo"), label: "Back", icon: "chevron.backward", span: 2),
        ]]),
    ])

    let kind = "photo"
    var layout: RAVESleeveLayout { Self.layout }

    private weak var model: PhotoWindowModel?
    private let returnToWindow: @MainActor () -> Void
    /// A slider being dragged: committed (tracked, and the 3D picture re-baked)
    /// once it is let go, as the popover does after its sliders settle.
    private var pendingAdjustment: (tile: String, seen: TimeInterval)?

    init(model: PhotoWindowModel, returnToWindow: @escaping @MainActor () -> Void) {
        self.model = model
        self.returnToWindow = returnToWindow
    }

    var isActive: Bool { model != nil }

    func refresh(_ wearer: RAVESleeveWearer) {
        guard let model else { return }
        let locked = model.controlsLocked
        let count = model.galleryImages.count
        let name = model.image.title ?? model.image.fileName ?? "Photo"
        let place = count > 1 ? "\(model.currentGalleryIndex + 1) of \(count) · " : ""
        set(wearer, Tile.title, RAVESleeveTileState(text: place + name))
        set(wearer, Tile.previous, RAVESleeveTileState(disabled: locked || !model.hasPreviousGalleryImage))
        set(wearer, Tile.next, RAVESleeveTileState(disabled: locked || !model.hasNextGalleryImage))
        set(wearer, Tile.chrome, RAVESleeveTileState(isOn: !model.isUIHidden))

        let generating = model.spatial3DImageState == .generating
        let realityKit = model.desiredViewingMode == .spatial3D && !model.isRawSplatMode
        let immersive = model.desiredViewingMode == .spatial3DImmersive && !model.isRawSplatMode
        let flat = !model.is3DMode && !model.isAIDepthMode && !model.isDioramaMode
        set(wearer, Tile.flat, RAVESleeveTileState(isOn: flat, disabled: locked))
        set(wearer, Tile.realityKit, RAVESleeveTileState(isOn: realityKit, disabled: locked || (generating && !realityKit)))
        set(wearer, Tile.immersive, RAVESleeveTileState(isOn: immersive, disabled: locked || (generating && !immersive)))
        set(wearer, Tile.aiDepth, RAVESleeveTileState(
            isOn: model.isAIDepthMode,
            disabled: locked || !model.isAIDepthAvailable || model.isAnimatedImage
                || model.isRealityKitDisplay || model.isProcessingAIDepth))

        let adjustments = model.currentAdjustments
        for slider in Self.sliders {
            let value = adjustments[keyPath: slider.keyPath]
            set(wearer, slider.tile, RAVESleeveTileState(
                fraction: Float(Self.position(of: value, slider)),
                text: "\(slider.label) \(Self.format(value, slider))"))
        }
    }

    func handle(_ event: RAVESleeveEvent, _ wearer: RAVESleeveWearer) {
        guard let model, let action = event.action else { return }
        switch (action.id, event.kind) {
        case (Action.previous, .fired):
            Task { await model.previousGalleryImage() }
        case (Action.next, .fired):
            Task { await model.nextGalleryImage() }
        case (Action.chrome, .toggled(let show)):
            if model.isUIHidden == show { model.toggleUIVisibility() }
        case (Action.window, .fired):
            returnToWindow()
        case (Action.flat, .fired):
            Task { await model.showFlat() }
        case (Action.realityKit, .fired):
            Task { await model.toggleRealityKit3D(immersive: false) }
        case (Action.immersive, .fired):
            Task { await model.toggleRealityKit3D(immersive: true) }
        case (Action.aiDepth, .fired):
            Task { await model.toggleAIDepth() }
        case (Action.adjustment, .value(let fraction)):
            guard let tile = action.argument, let slider = Self.sliders.first(where: { $0.tile == tile }) else { return }
            // Live, as the popover's sliders are: the flat picture follows at once.
            model.currentAdjustments[keyPath: slider.keyPath] = Self.value(at: Double(fraction), slider)
            pendingAdjustment = (tile, CACurrentMediaTime())
        case (Action.reset, .fired):
            // The popover's Reset (auto-enhance is its own toggle and stays).
            model.currentAdjustments.brightness = 0
            model.currentAdjustments.contrast = 1
            model.currentAdjustments.saturation = 1
            model.currentAdjustments.sharpen = 0
            model.currentAdjustments.opacity = 1
            model.currentAdjustments.scale = 1
            model.currentAdjustments.immersiveScale = 1
            commitAdjustments(model)
        default:
            break
        }
    }

    func stepped(_ wearer: RAVESleeveWearer) {
        guard let pending = pendingAdjustment, let model else { return }
        let held = wearer.snapshot?.tiles.first { $0.tile.id == pending.tile }?.isPressed ?? false
        guard !held, CACurrentMediaTime() - pending.seen > 0.12 else { return }
        pendingAdjustment = nil
        commitAdjustments(model)
    }

    func released() {
        if let model, pendingAdjustment != nil { commitAdjustments(model) }
        pendingAdjustment = nil
    }

    /// What the popover does when its values change: remember them for the
    /// picture, and re-bake a 3D picture (which waits for the values to settle).
    private func commitAdjustments(_ model: PhotoWindowModel) {
        Task { await model.trackAdjustments() }
        model.reloadImagePresentationWithAdjustments()
    }

    private static func position(of value: Double, _ slider: Slider) -> Double {
        if slider.linear {
            return (value - slider.range.lowerBound) / (slider.range.upperBound - slider.range.lowerBound)
        }
        return VisualAdjustmentsPopover.sliderPosition(of: value, in: slider.range, defaultValue: slider.defaultValue)
    }

    private static func value(at position: Double, _ slider: Slider) -> Double {
        let t = min(max(position, 0), 1)
        if slider.linear {
            return slider.range.lowerBound + t * (slider.range.upperBound - slider.range.lowerBound)
        }
        return VisualAdjustmentsPopover.value(atSliderPosition: t, in: slider.range, defaultValue: slider.defaultValue)
    }

    private static func format(_ value: Double, _ slider: Slider) -> String {
        if slider.tile == Tile.opacity { return "\(Int((value * 100).rounded()))%" }
        let delta = value - slider.defaultValue
        return abs(delta) < 0.005 ? "0" : String(format: "%+.2f", delta)
    }
}

#endif
