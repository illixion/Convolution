/*
 MatroskaRemux - Stable Audio: a decoded track levelled around its dialogue

 Films are mixed for a cinema: effects and music peak near full scale while
 dialogue sits 20-30 dB below them, and the centre channel that carries it
 is sometimes mixed too hot, sometimes too quiet. At home that means riding
 the volume. A track the session decodes anyway (`AudioTranscode`) can be
 offered a second time, processed, as its own rendition ("English
 (Stable)"), and the player switches between the two like any audio tracks.

 Four stages, in order, all driven from 10 ms analysis blocks with gains
 ramped across each block:

 1. Dialogue detection. Speech sits in the centre channel (in a stereo
    track, the mid signal), and most of its energy is in the voice band:
    a centre whose 250 Hz - 3.5 kHz band holds over 40% of its power, and
    is above -55 dBFS, is taken as someone talking. An explosion in the
    centre is mostly below that band and doesn't count. Its level, smoothed
    over about half a second while it lasts, is the dialogue level.
 2. The bed ducks under the dialogue. While someone talks, the other
    channels (fronts, surrounds, LFE) come down until they are no more than
    4 dB above the dialogue, by at most 9 dB; they come back over 400 ms.
    This is what Enhance Dialogue does by ear: the voice is never lowered,
    the effects make room for it.
 3. Presence. A +3 dB peak at 2.8 kHz on the centre (not on a stereo
    track, where it would brighten everything).
 4. Levelling and limiting. The dialogue level is brought to -27 dBFS
    (by at most +9/-9 dB; until there has been dialogue, the mix's
    loudness towards -24 at 3:1). Whatever that leaves louder than -20
    (BS.1770's channel weights, 300 ms, the bed as ducked) comes down at
    3:1, and nothing below -60 is lifted (room tone stays room tone). Then
    a 5 ms look-ahead limiter holds peaks to -1 dBFS.

 Each segment is processed on its own, like its decode, after
 `primingSeconds` of the previous segment's audio (decoded and processed,
 then dropped), which settles the envelopes and filters to within a few
 percent of a straight-through run: the seam between segments is inaudible,
 and a segment asked for twice is the same bytes (`RemuxSession.transcoded`).
 */

import Foundation

enum StableAudio {
    /// How much of the previous segment runs through first: the slowest
    /// envelope (the leveller's 800 ms release) has settled to ~8% by then,
    /// the ducking to under 1%.
    static let primingSeconds = 2.0

    /// Processes planar channels in ALAC order (C L R Ls Rs LFE, or L R for
    /// stereo, or a single channel), full scale ±1, in place.
    static func process(_ channels: inout [[Float]], sampleRate: Int) {
        let count = channels.count
        guard count > 0, let frames = channels.first?.count, frames > 0, sampleRate > 0 else { return }
        let roles = Roles(channels: count)
        let rate = Float(sampleRate)
        let block = max(1, sampleRate / 100)
        let blockSeconds = Float(block) / rate

        // Detector filters, run on copies (the voice band of the centre or
        // mid signal); the presence EQ runs on the centre itself.
        var bandHigh = Biquad.highPass(250, rate: rate)
        var bandLow = Biquad.lowPass(3500, rate: rate)
        var presence = Biquad.peaking(2800, gainDB: 3, q: 0.9, rate: rate)

        // Smoothed state, in dB unless named otherwise.
        var speech: Float = 0 // 0...1
        var heardDialogue = false
        var dialogue: Float = -70
        var bed: Float = -90
        var loudness: Float = -70
        var duck: Float = 0 // ≤ 0
        var level: Float = 0
        var previousDuck: Float = 1, previousLevel: Float = 1 // linear, at the last block's end

        func smoothing(_ seconds: Float) -> Float { 1 - exp(-blockSeconds / seconds) }
        let speechAttack = smoothing(0.03), speechRelease = smoothing(0.3)
        let dialogueRate = smoothing(0.5)
        let bedAttack = smoothing(0.01), bedRelease = smoothing(0.2)
        let loudnessRate = smoothing(0.3)
        let duckAttack = smoothing(0.03), duckRelease = smoothing(0.4)
        let levelAttack = smoothing(0.05), levelRelease = smoothing(0.8)

        var start = 0
        while start < frames {
            let n = min(block, frames - start)
            // Powers over this block.
            var voice: Float = 0, centre: Float = 0, bedPower: Float = 0
            var centreWeighted: Float = 0, bedWeighted: Float = 0
            for i in start ..< start + n {
                let talker: Float = if let c = roles.centre { channels[c][i] }
                    else if count >= 2 { 0.5 * (channels[0][i] + channels[1][i]) } else { channels[0][i] }
                let band = bandLow.run(bandHigh.run(talker))
                voice += band * band
                centre += talker * talker
                for c in roles.bed { bedPower += channels[c][i] * channels[c][i] }
                for c in roles.front {
                    if c == roles.centre { centreWeighted += channels[c][i] * channels[c][i] }
                    else { bedWeighted += channels[c][i] * channels[c][i] }
                }
                for c in roles.surround { bedWeighted += 1.41 * channels[c][i] * channels[c][i] }
            }
            let scale = 1 / Float(n)
            let voiceDB = decibels(voice * scale), centreDB = decibels(centre * scale)
            let bedDB = decibels(bedPower * scale)

            // 1. Is someone talking, and how loud.
            let talking: Float = voiceDB > -55 && voiceDB - centreDB > -4 ? 1 : 0
            speech += (talking - speech) * (talking > speech ? speechAttack : speechRelease)
            if talking > 0 {
                dialogue = heardDialogue ? dialogue + (voiceDB - dialogue) * dialogueRate : voiceDB
                heardDialogue = true
            }

            // 2. The bed under the dialogue (stereo has no separate bed).
            bed += (bedDB - bed) * (bedDB > bed ? bedAttack : bedRelease)
            let wantedDuck: Float = roles.bed.isEmpty || roles.centre == nil ? 0
                : -min(9, max(0, bed - (dialogue + 4))) * speech
            duck += (wantedDuck - duck) * (wantedDuck < duck ? duckAttack : duckRelease)

            // 4. The leveller: the dialogue to -27 dBFS once there has been
            // some (before that, the mix 3:1 around -24), and whatever that
            // makes louder than -20 back down at 3:1. Loudness is measured
            // with the bed as ducked.
            let duckPower = pow(10, duck / 10)
            let loudDB = decibels((centreWeighted + bedWeighted * duckPower) * scale)
            loudness += (loudDB - loudness) * loudnessRate
            var wantedLevel = heardDialogue ? max(-9, -27 - dialogue) : (loudness + 24) * (1.0 / 3 - 1)
            let out = loudness + wantedLevel
            if out > -20 { wantedLevel -= (out + 20) * (1 - 1.0 / 3) }
            wantedLevel = min(9, wantedLevel)
            // Room tone stays room tone: no lift below -60, none at all by -70.
            if loudness < -60, wantedLevel > 0 { wantedLevel *= max(0, (loudness + 70) / 10) }
            level += (wantedLevel - level) * (wantedLevel < level ? levelAttack : levelRelease)

            // Ramp both gains across the block.
            let duckGain = linear(duck), levelGain = linear(level)
            for j in 0 ..< n {
                let t = Float(j + 1) / Float(n)
                let d = previousDuck + (duckGain - previousDuck) * t
                let g = previousLevel + (levelGain - previousLevel) * t
                let i = start + j
                if let c = roles.centre { channels[c][i] = presence.run(channels[c][i]) * g }
                for c in roles.bed { channels[c][i] *= d * g }
                if roles.centre == nil { for c in 0 ..< count { channels[c][i] *= g } }
            }
            previousDuck = duckGain
            previousLevel = levelGain
            start += n
        }

        limit(&channels, sampleRate: sampleRate)
    }

    /// Holds every peak to -1 dBFS: the gain each sample needs, the lowest
    /// over the next 5 ms (so the gain is down before the peak arrives),
    /// released over 80 ms.
    static func limit(_ channels: inout [[Float]], sampleRate: Int) {
        let frames = channels[0].count
        let ceiling: Float = 0.891
        let lookahead = max(1, sampleRate / 200)
        var needed = [Float](repeating: 1, count: frames)
        var any = false
        for i in 0 ..< frames {
            var peak: Float = 0
            for c in channels.indices { peak = max(peak, abs(channels[c][i])) }
            if peak > ceiling { needed[i] = ceiling / peak; any = true }
        }
        guard any else { return }
        // The minimum over [i, i + lookahead], with a monotonic queue.
        var windowed = [Float](repeating: 1, count: frames)
        var queue: [Int] = []
        queue.reserveCapacity(lookahead + 1)
        var head = 0
        var next = 0
        for i in 0 ..< frames {
            while next < frames, next <= i + lookahead {
                while queue.count > head, needed[queue[queue.count - 1]] >= needed[next] { queue.removeLast() }
                queue.append(next)
                next += 1
            }
            while queue[head] < i { head += 1 }
            windowed[i] = needed[queue[head]]
            if head > 4096 { queue.removeFirst(head); head = 0 }
        }
        let release = 1 - exp(-1 / (0.08 * Float(sampleRate)))
        var gain: Float = 1
        for i in 0 ..< frames {
            let target = windowed[i]
            gain = target < gain ? target : gain + (target - gain) * release
            for c in channels.indices { channels[c][i] = max(-ceiling, min(ceiling, channels[c][i] * gain)) }
        }
    }

    /// Which channel does what, in ALAC order.
    struct Roles {
        var centre: Int?
        var front: [Int] = []
        var surround: [Int] = []
        /// Ducked under the dialogue: everything but the centre.
        var bed: [Int] = []

        init(channels: Int) {
            switch channels {
            case 1: front = [0]
            case 2: front = [0, 1]
            default:
                centre = 0
                front = [0, 1, 2]
                surround = channels >= 5 ? [3, 4] : []
                bed = Array(1 ..< channels)
            }
        }
    }

    static func decibels(_ power: Float) -> Float { 10 * log10(max(power, 1e-10)) }
    static func linear(_ decibels: Float) -> Float { pow(10, decibels / 20) }
}

/// A second-order IIR section (RBJ's cookbook), transposed direct form II.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var z1: Float = 0, z2: Float = 0

    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    static func highPass(_ frequency: Float, rate: Float, q: Float = 0.7071) -> Biquad {
        let w = 2 * Float.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func lowPass(_ frequency: Float, rate: Float, q: Float = 0.7071) -> Biquad {
        let w = 2 * Float.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peaking(_ frequency: Float, gainDB: Float, q: Float, rate: Float) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * Float.pi * frequency / rate
        let alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }
}
