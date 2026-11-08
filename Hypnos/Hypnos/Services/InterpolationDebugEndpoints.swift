/*
 Hypnos - frame-interpolation model timing on the debug server

 `interpModelBench` runs Vergence's `InterpolationModelBenchmark` over the
 Core ML models in Documents/InterpModels (pushed there by
 `scripts/convert-interp-model.py --push` or devicectl): phase E0 of
 `docs/plans/blu-ray-3d-smooth-motion.md`. Returns timings and op placement
 only; the model names are the converter's own file names. `interpFlowBench`
 times the GPU interpolator (`FlowInterpolationBenchmark`) the same way, and
 `upscaleBench` AI Upscaling's VideoToolbox super resolution
 (`RealtimeUpscalerBenchmark`): its factors and limits on this device, each
 size's model load and the time a frame takes with its conversions.
 */

import DebugTrace
import Foundation
import VergenceApple

@MainActor
enum InterpolationDebugEndpoints {
    private static var registered = false

    static var modelFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InterpModels", isDirectory: true)
    }

    static func register() {
        guard !registered else { return }
        registered = true
        DebugSurface.shared.register([
            .command("interpModelBench", "Time the frame-interpolation Core ML models in Documents/InterpModels on "
                     + "each compute-unit choice (cpuAndNeuralEngine, cpuAndGPU, all): load, median/p90/best ms per "
                     + "prediction, and which ops Core ML placed off the Neural Engine. Takes up to a few minutes.",
                     parameters: [
                        .string("units", "comma-separated compute-unit choices; default all three"),
                        .string("only", "only models whose file name contains this"),
                        .integer("iterations", "timed predictions per model and choice", default: 30, range: 1 ... 500),
                     ],
                     timeout: .seconds(900)) { args in
                let units = (args.string("units") ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return await InterpolationModelBenchmark.run(folder: modelFolder, units: units,
                                                             iterations: args.int("iterations") ?? 30,
                                                             only: args.string("only"))
            },
            .command("interpFlowBench", "Time the GPU frame interpolator (Fast (GPU), Vergence's "
                     + "FlowMidFrameInterpolator) on synthetic frames, away from playback: GPU and wall ms "
                     + "(median, p90) at 1080p and 720p, with and without the motion output AI 3D's depth reads.",
                     parameters: [
                        .integer("iterations", "timed frames per size", default: 120, range: 10 ... 2000),
                     ],
                     timeout: .seconds(300)) { args in
                await FlowInterpolationBenchmark.run(sizes: [(1920, 1080), (1280, 720)],
                                                     iterations: args.int("iterations") ?? 120)
            },
        ])
        #if !targetEnvironment(simulator)
        DebugSurface.shared.register([
            .command("upscaleBench", "Time AI Upscaling's VideoToolbox super resolution (Vergence's "
                     + "VTRealtimeUpscaler) on synthetic frames, away from playback: the factors and input limits "
                     + "this device has, and for 640×360, 854×480, 960×540 and 1280×720 the factor playback uses, the "
                     + "model load ms and the wall ms a frame takes with its format conversions (median, p90, best).",
                     parameters: [
                        .integer("iterations", "timed frames per size", default: 120, range: 10 ... 2000),
                     ],
                     timeout: .seconds(300)) { args in
                await RealtimeUpscalerBenchmark.run(iterations: args.int("iterations") ?? 120)
            },
        ])
        #endif
    }
}
