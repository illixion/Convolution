/*
 Hypnos - HUD framing: keeping the HUD's picture in view

 The HUD hangs from a smoothed copy of the head (`CinemaHUDFollow`) at a
 `hudOffset` the wearer drags it to. Two things could put the picture out of
 sight, and this file bounds both. It is pure maths (Foundation and simd), so
 it builds and is checked off the headset.

 1. **Where it may sit.** The picture's centre is kept inside the usable field
    of view with the whole picture, so dragging it sideways, up or down stops
    where its edge would leave the view. Its distance may go down to 0.5 m,
    and the nearer it comes the less of the view it may take: past
    `maxPictureAngle` the picture stops growing and keeps that angular size,
    so a close picture shrinks instead of overflowing.
 2. **How far the smoothing may lag.** The follow eases toward the real head so
    the picture doesn't shake with every step, but a fast turn or a stride
    would leave the picture behind. What the framing leaves free around the
    picture (`slack`) is how far the smoothed head may be from the real one,
    split between turning (`rotationShare`) and moving, so the smoothing
    softens jitter and a fast movement still can't take the picture out of view.

 The field of view is a conservative estimate, not a measurement: the headset's
 real one is wider and varies with the fit. Both numbers are in one place so
 a device check can move them.
 */

import Foundation
import simd

enum HUDFraming {
    /// Nearest and farthest the picture's centre may be from the head, metres.
    static let minDistance: Float = 0.5
    static let maxDistance: Float = 6

    /// The half field of view the picture has to stay inside (horizontal,
    /// vertical), radians. Narrower than the headset's, on purpose.
    static let halfFieldOfView = SIMD2<Float>(50, 40) * (.pi / 180)

    /// The most of the view the picture may take (full width, full height),
    /// radians. Closer than this allows, the picture shrinks to keep it.
    static let maxPictureAngle = SIMD2<Float>(70, 42) * (.pi / 180)

    /// Angle kept free past the picture's edge for the smoothing's lag, radians.
    static let lagReserve: Float = 6 * .pi / 180

    /// The least lag allowed even when the picture fills the view, so the
    /// smoothing never turns into a rigid lock on a picture that can't fit.
    static let minimumSlack: Float = 2 * .pi / 180

    /// Share of the slack the smoothed head may turn away by; the rest goes to
    /// moving away (sideways, at the picture's distance).
    static let rotationShare: Float = 0.6

    // MARK: Size

    /// The width the picture is drawn at: what was asked for, capped so its
    /// angular size at `distance` stays within `maxPictureAngle`.
    static func pictureWidth(requested: Float, aspect: Float, distance: Float) -> Float {
        let aspect = max(aspect, 0.1)
        let distance = max(distance, minDistance)
        let byWidth = 2 * distance * tan(maxPictureAngle.x / 2)
        let byHeight = 2 * distance * tan(maxPictureAngle.y / 2) * aspect
        return min(requested, byWidth, byHeight)
    }

    /// Half the picture's angular width and height seen from its centre's distance.
    private static func halfExtents(width: Float, aspect: Float, distance: Float) -> SIMD2<Float> {
        SIMD2(atan(width / 2 / distance), atan(width / max(aspect, 0.1) / 2 / distance))
    }

    // MARK: Placement

    /// The nearest offset to `offset` (from the smoothed head, −z ahead) at
    /// which the whole picture is inside the field of view and the distance is
    /// within bounds. An offset already inside comes back unchanged.
    static func clamp(offset: SIMD3<Float>, requestedWidth: Float, aspect: Float) -> SIMD3<Float> {
        let length = simd_length(offset)
        guard length.isFinite, offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else {
            return SIMD3(0, 0, -2)
        }
        let direction = length > 1e-4 ? offset / length : SIMD3<Float>(0, 0, -1)
        let distance = min(maxDistance, max(minDistance, length))
        let width = pictureWidth(requested: requestedWidth, aspect: aspect, distance: distance)
        let half = halfExtents(width: width, aspect: aspect, distance: distance)

        let azimuth = atan2(direction.x, -direction.z)
        let elevation = asin(min(1, max(-1, direction.y)))
        let azimuthLimit = max(0, halfFieldOfView.x - half.x - lagReserve)
        let elevationLimit = max(0, halfFieldOfView.y - half.y - lagReserve)
        let clampedAzimuth = min(azimuthLimit, max(-azimuthLimit, azimuth))
        let clampedElevation = min(elevationLimit, max(-elevationLimit, elevation))

        if distance == length, clampedAzimuth == azimuth, clampedElevation == elevation { return offset }
        let flat = cos(clampedElevation)
        return SIMD3(sin(clampedAzimuth) * flat, sin(clampedElevation), -cos(clampedAzimuth) * flat) * distance
    }

    // MARK: Smoothing

    /// How far the smoothed head may be from the real one: a turn (radians)
    /// and a move (metres), from what the picture leaves free of the view.
    /// `stabilization` (0 ... 1) scales that range of motion: 1 is all the
    /// view leaves free, less shrinks it, and 0 locks the picture to the head.
    static func lagLimits(offset: SIMD3<Float>, requestedWidth: Float, aspect: Float,
                          stabilization: Float = 1) -> (rotation: Float, position: Float) {
        let scale = stabilization.isFinite ? min(1, max(0, stabilization)) : 1
        let length = simd_length(offset)
        guard length.isFinite, length > 1e-4 else { return (minimumSlack * rotationShare * scale, 0) }
        let distance = min(maxDistance, max(minDistance, length))
        let width = pictureWidth(requested: requestedWidth, aspect: aspect, distance: distance)
        let half = halfExtents(width: width, aspect: aspect, distance: distance)
        let direction = offset / length
        let azimuth = abs(atan2(direction.x, -direction.z))
        let elevation = abs(asin(min(1, max(-1, direction.y))))
        let slack = max(minimumSlack,
                        min(halfFieldOfView.x - half.x - azimuth, halfFieldOfView.y - half.y - elevation))
        return (slack * scale * rotationShare, slack * scale * (1 - rotationShare) * distance)
    }

    /// `smoothed` pulled back toward `target` until it is no more than `maxAngle` from it.
    static func limit(_ smoothed: simd_quatf, toward target: simd_quatf, by maxAngle: Float) -> simd_quatf {
        let relative = target.inverse * smoothed
        let angle = 2 * atan2(simd_length(relative.imag), abs(relative.real))
        guard angle.isFinite, angle > maxAngle, angle > 1e-6 else { return smoothed }
        return simd_slerp(target, smoothed, maxAngle / angle)
    }

    /// `smoothed` pulled back toward `target` until it is no more than `maxDistance` from it.
    static func limit(_ smoothed: SIMD3<Float>, near target: SIMD3<Float>, by maxDistance: Float) -> SIMD3<Float> {
        let delta = smoothed - target
        let length = simd_length(delta)
        guard length.isFinite, length > maxDistance, length > 1e-6 else { return smoothed }
        return target + delta * (maxDistance / length)
    }
}
