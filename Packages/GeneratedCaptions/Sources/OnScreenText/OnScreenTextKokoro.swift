/*
 On-screen text: Kokoro voices.

 Kokoro-82M (FluidAudio's `KokoroAneManager`, the seven-stage Core ML chain)
 as a narration voice: English, American and British, 28 voices, far more
 natural than the system's default ones. Its models are downloaded once from
 Hugging Face (FluidInference/kokoro-82m-coreml) into Application Support and
 compiled on the device; the first load after that takes about 20 s, later
 ones well under a second. A voice pack is fetched the first time it is used.

 Loaded only while narration runs and released when it stops (`unload`), so
 it costs nothing on a video that isn't narrated. The legacy runtime with
 FluidAudio's default routing keeps the GPU out of the chain on OS 27, which
 the video needs, and avoids the MPSGraph abort FluidAudio reports there.

 FluidAudio warns that on iOS/visionOS 27 a long session can still crash in
 libBNNS (FluidAudio #889); the system voices have no such risk, so Kokoro is
 an opt-in choice in Settings, never the default. A Vision Pro on 27.2 did
 crash that way 22 minutes into a narrated video (2026-11-16), and two things
 here could have run predictions side by side: a line cancelled by a stop or
 a seek kept running while the next one started (the manager is an actor,
 re-entered at every stage's `await`), and an unload could free the models
 under it. So every line, load and unload takes `OnScreenCoreMLTurn`, which
 also keeps Vision's reading from running beside them.
 */

import AVFoundation
import FluidAudio
import Foundation

public actor OnScreenTextKokoro {
    public static let shared = OnScreenTextKokoro()

    /// A narrator voice identifier naming a Kokoro voice: this prefix and the
    /// voice pack's name (`kokoro:af_heart`).
    public static let identifierPrefix = "kokoro:"

    public struct Voice: Sendable, Hashable, Identifiable {
        /// The voice pack, `af_heart`.
        public let id: String
        public var identifier: String { OnScreenTextKokoro.identifierPrefix + id }
        /// `Heart`.
        public var name: String {
            let base = id.split(separator: "_").dropFirst().joined(separator: " ")
            return base.prefix(1).uppercased() + base.dropFirst()
        }
        public var isBritish: Bool { id.hasPrefix("b") }
        public var isFemale: Bool { id.dropFirst().hasPrefix("f") }
        /// `American English · Female`.
        public var detail: String {
            "\(isBritish ? "British" : "American") English · \(isFemale ? "Female" : "Male")"
        }
    }

    /// The English voices (American and British); Kokoro's others speak
    /// English phonemes with a foreign timbre, which isn't what they are for.
    public static let voices: [Voice] = KokoroAneConstants.englishVoices
        .filter { ["af_", "am_", "bf_", "bm_"].contains(String($0.prefix(3))) }
        .map(Voice.init)

    public static func voice(forIdentifier identifier: String?) -> Voice? {
        guard let identifier, identifier.hasPrefix(identifierPrefix) else { return nil }
        let id = String(identifier.dropFirst(identifierPrefix.count))
        return voices.first { $0.id == id }
    }

    /// Where its models live.
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "OnScreenText/Kokoro", directoryHint: .isDirectory)
    }
    private static var readyMarker: URL { directory.appending(path: "ready") }

    /// The models have been downloaded and loaded once.
    public static var isDownloaded: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// The models' size on disk, in bytes.
    public static func diskSize() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // Who is using the models (a narrating video, the Settings sample, a
    // download). Counted outside the actor so a retain is never reordered
    // behind a release; the models unload when the last user lets go.
    private nonisolated let users = NSLock()
    private nonisolated(unsafe) var userCount = 0

    /// Marks the models as in use; pair with `release()`.
    public nonisolated func retain() {
        users.withLock { userCount += 1 }
    }

    /// Ends one use; the last one out unloads the models.
    public nonisolated func release() {
        let idle = users.withLock { () -> Bool in
            userCount = max(0, userCount - 1)
            return userCount == 0
        }
        if idle { Task { await unloadIfIdle() } }
    }

    private func unloadIfIdle() async {
        guard users.withLock({ userCount }) == 0 else { return }
        await unload()
    }

    private var manager: KokoroAneManager?
    private var loading: Task<KokoroAneManager, Error>?
    /// Moves on with each unload, so a load that finishes after one is not
    /// adopted (the unload has freed it).
    private var loadGeneration = 0

    /// Downloads (the first time) and loads the models.
    public func prepare() async throws {
        _ = try await loaded()
    }

    /// `text` spoken in `voice` (a pack name), at `speed` (1 normal): 24 kHz mono.
    public func synthesize(_ text: String, voice: String, speed: Float) async throws -> sending AVAudioPCMBuffer {
        let manager = try await loaded()
        let speed = min(1.5, max(0.5, speed))
        // A line is under a second on a headset: one that has run 20 s is
        // hung, and a waiter may take the turn from it (narration then falls
        // back to the system voice, and Vision reads on).
        let result = try await OnScreenCoreMLTurn.shared.run(timeout: 20, patience: 20) {
            try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
        }
        guard !result.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(result.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(result.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw CocoaError(.featureUnsupported) }
        result.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        buffer.frameLength = AVAudioFrameCount(result.samples.count)
        return buffer
    }

    /// Releases the loaded models (they stay on disk). Prefer `release()`,
    /// which leaves them loaded while anything else is using them.
    func unload() async {
        // A load can't be stopped part way; let it finish, then free it too.
        let pending = loading
        loading = nil
        let current = manager
        manager = nil
        loadGeneration += 1
        let loadedMeanwhile = try? await pending?.value
        try? await OnScreenCoreMLTurn.shared.run(patience: 60) {
            if let current { await current.cleanup() }
            if let loadedMeanwhile, loadedMeanwhile !== current { await loadedMeanwhile.cleanup() }
        }
    }

    /// Deletes the downloaded models.
    public func remove() async throws {
        await unload()
        if FileManager.default.fileExists(atPath: Self.directory.path) {
            try FileManager.default.removeItem(at: Self.directory)
        }
    }

    private func loaded() async throws -> KokoroAneManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task<KokoroAneManager, Error> {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            var excluded = Self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            let manager = KokoroAneManager(directory: Self.directory)
            try await OnScreenCoreMLTurn.shared.run(patience: 300) { try await manager.initialize() }
            FileManager.default.createFile(atPath: Self.readyMarker.path, contents: Data())
            return manager
        }
        loading = task
        let generation = loadGeneration
        do {
            let manager = try await task.value
            guard generation == loadGeneration else { throw CancellationError() }
            self.manager = manager
            loading = nil
            return manager
        } catch {
            if generation == loadGeneration { loading = nil }
            throw error
        }
    }
}
