/*
 Hypnos - Thumbnail Depth Estimator

 Runs the real-time depth model over gallery thumbnails, one at a time, for
 the "3D Depth" thumbnail style. Scrolling is what decides the load, so the
 queue is built for flicks rather than throughput:

 - Newest request first. The cell the user just stopped on is the one they
   are looking at; what scrolled in a second ago is likely gone already.
 - A cancelled request (its cell scrolled away) is dropped before it ever
   reaches the model, so a fast flick costs no inference at all.
 - One inference in flight, at utility priority, on a single provider: the
   ANE is shared with any fake-3D video playing in another window.
 - The model is released after a short idle, since a gallery that is only
   being looked at needs none of its memory.

 Uses the real-time model role: the small, fast model is the right trade for
 a 1000 px thumbnail, and it is the one every installed setup has.
 */

import CoreGraphics
import DebugTrace
import Foundation
import Metal
import RAVEMedia

@MainActor
final class ThumbnailDepthEstimator {
    static let shared = ThumbnailDepthEstimator()

    /// Main-actor confined; `@unchecked` only so the cancellation handler can
    /// carry it back onto the main actor.
    private final class Job: @unchecked Sendable {
        let image: CGImage
        var continuation: CheckedContinuation<StillDepthMap?, Never>?
        init(image: CGImage) { self.image = image }

        func finish(_ map: StillDepthMap?) {
            continuation?.resume(returning: map)
            continuation = nil
        }
    }

    private var pending: [Job] = []
    private var running = false
    private let worker = Worker()
    private var modelCheck: (available: Bool, at: Date)?

    private init() {}

    /// Whether a depth model is installed. Cached briefly: every cell asks on
    /// appear, and the answer only changes when the user installs or deletes
    /// a model in Settings.
    var isModelAvailable: Bool {
        if let modelCheck, Date().timeIntervalSince(modelCheck.at) < 5 { return modelCheck.available }
        let available = CoreMLDepthProvider.hasAvailableModel(role: .realtime)
        modelCheck = (available, Date())
        return available
    }

    /// Depth for `image`, or nil when there is no model, inference failed, or
    /// the calling task was cancelled while waiting its turn.
    func depth(for image: CGImage) async -> StillDepthMap? {
        let job = Job(image: image)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                job.continuation = continuation
                pending.append(job)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(job) }
        }
    }

    private func cancel(_ job: Job) {
        guard let index = pending.firstIndex(where: { $0 === job }) else { return }
        pending.remove(at: index)
        job.finish(nil)
    }

    private func pump() {
        guard !running, let job = pending.popLast() else { return }
        running = true
        let image = job.image
        Task {
            let map = await worker.infer(image)
            job.finish(map)
            running = false
            pump()
        }
    }

    /// Owns the provider. Touched only on `queue`.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.illixion.hypnos.thumbnailDepth", qos: .utility)
        private var provider: CoreMLDepthProvider?
        private var modelName: String?
        private var generation = 0
        /// Long enough to span a pause between flicks; short enough that a
        /// gallery left on screen doesn't keep a model resident.
        private static let idleRelease: TimeInterval = 20

        func infer(_ image: CGImage) async -> StillDepthMap? {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.inferOnQueue(image))
                }
            }
        }

        private func inferOnQueue(_ image: CGImage) -> StillDepthMap? {
            generation += 1
            let mine = generation
            defer {
                queue.asyncAfter(deadline: .now() + Self.idleRelease) { [weak self] in
                    guard let self, self.generation == mine, self.provider != nil else { return }
                    self.provider = nil
                    self.modelName = nil
                    AppLogger.backgroundRemover.debug("Thumbnail depth model released after idle")
                }
            }
            // Follow the Settings choice: a model swap takes effect on the
            // next thumbnail instead of needing a relaunch.
            guard let name = CoreMLDepthProvider.resolvedModelName(role: .realtime) else {
                provider = nil
                modelName = nil
                return nil
            }
            if provider == nil || modelName != name {
                guard let device = MTLCreateSystemDefaultDevice() else { return nil }
                let start = Date()
                provider = CoreMLDepthProvider(device: device, role: .realtime)
                modelName = name
                AppLogger.backgroundRemover.info("Thumbnail depth model loaded in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
            }
            guard let provider else { return nil }
            let start = Date()
            let map = provider.stillDepth(for: image)
            AppLogger.backgroundRemover.debug("Thumbnail depth \(image.width, privacy: .public)x\(image.height, privacy: .public) in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
            return map
        }
    }
}
