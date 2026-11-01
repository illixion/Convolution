/*
 Hypnos - frame-interpolation model timing on the debug server

 `interpModelBench` runs Vergence's `InterpolationModelBenchmark` over the
 Core ML models in Documents/InterpModels (pushed there by
 `scripts/convert-interp-model.py --push` or devicectl): phase E0 of
 `docs/plans/blu-ray-3d-smooth-motion.md`. Returns timings and op placement
 only; the model names are the converter's own file names.
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
        ])
    }
}
