#if HYPNOS_NC_MODELS
/*
 Hypnos - larger depth models under non-commercial licences (sideload only)

 The App Store build offers only Depth Anything V2 Small (Apache-2.0, from
 Apple's own repo). The sideload (GitHub) edition may also offer its larger
 relatives, whose weights are CC-BY-NC-4.0: non-commercial use only. This
 whole file, the models' names and addresses, and the download section that
 shows their licence exist only with `NC_MODELS_CONDITION=HYPNOS_NC_MODELS`
 (CLAUDE.md, "Larger depth models are sideload-only"); a submission build
 compiles none of it. Nothing is re-hosted: the Core ML conversions are a
 third party's on Hugging Face, downloaded from there.

 Measured on an M2 Max through the offline pipeline (1080p, 2026-11-07):
 Small 23–35 fps, this Base 9–12 fps. Base resolves fine structure Small
 misses (fibres, thin stems). A conversion made with
 `scripts/convert-depth-model.py --variant base` (518×392, the precision
 ladder) was sharper still and haloed less than this archive's all-float16
 518×518 one, and can be dropped into Documents instead. Large is a
 pre-processing model: several times slower again.

 Not offered: Video Depth Anything (it reads clips of 32 frames, not one
 frame, so it doesn't fit the per-frame pipeline) and Depth Pro (1536×1536
 input at seconds a frame, an image output the provider doesn't read, and
 research-only weights).
 */

import Foundation
import RAVEMedia

enum NonCommercialDepthModels {
    static let licence = DepthModelManager.Licence(
        name: "CC-BY-NC-4.0",
        url: URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")!,
        nonCommercial: true,
        attribution: "Depth Anything V2 (Yang et al., 2024), converted to Core ML by mrgnw on Hugging Face")

    static let variants: [DepthModelManager.Variant] = [
        DepthModelManager.Variant(
            name: "DepthAnythingV2BaseF16", displayName: "Depth Anything V2 Base (F16)",
            subtitle: "Sharper fine detail · non-commercial · best for Pre-Process", approxBytes: 179_859_157,
            archive: .init(repo: "mrgnw/depth-anything-v2-coreml", file: "DepthAnythingV2BaseF16.mlpackage.tar.gz"),
            licence: licence),
        DepthModelManager.Variant(
            name: "DepthAnythingV2LargeF16", displayName: "Depth Anything V2 Large (F16)",
            subtitle: "Pre-Process only, slow · non-commercial", approxBytes: 618_722_036,
            archive: .init(repo: "mrgnw/depth-anything-v2-coreml", file: "DepthAnythingV2LargeF16.mlpackage.tar.gz"),
            licence: licence),
    ]

    /// Offers them in the AI Models sheet (once, at launch).
    @MainActor static func register() {
        DepthModelManager.additionalVariants = variants
    }
}
#endif
