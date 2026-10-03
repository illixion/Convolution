# Third-party notices

Convolution (the visionOS/iOS/tvOS/macOS app) and the Jellyfin Atmos Objects plugin
(`JellyfinPlugin/`) are two separately-distributed pieces of software, so this
file separates which notice applies to which. Nothing below is linked into
both — see each entry's "Used by" line.

---

## Cavern

**Used by:** the Jellyfin plugin only (`JellyfinPlugin/Jellyfin.Plugin.AtmosObjects/Eac3AtmosDecoder.cs`),
via the official NuGet packages `Cavern` and `Cavern.Format` 2.1.0. Decodes the
JOC (Joint Object Coding) objects out of an E-AC-3 (Dolby Digital Plus Atmos)
track in-process.

- Project: <https://github.com/VoidXH/Cavern>
- Creator: Bence Sgánetz — <http://en.sbence.hu>

Cavern's licence is not SPDX-standard; its terms require crediting the creator
with a link whenever the software is used publicly or commercially (e.g. as an
API in another piece of software, which is exactly this plugin's use of it),
and forbid selling it, showing ads in a modified build, or removing this
attribution if the source is modified. **This credit line fulfils that
requirement:** Atmos object decoding for E-AC-3 tracks is powered by
[Cavern](https://github.com/VoidXH/Cavern) by Bence Sgánetz
(<http://en.sbence.hu>). Cavern is used unmodified (via NuGet, not a
source checkout) and must stay confined to the plugin — see
`~/CLAUDE.md`'s project notes for why it must never be linked into the
Convolution app itself.

Full licence text (`LICENSE.md` in the Cavern repository), reproduced verbatim:

> Cavern licence
>
> By downloading, using, copying, modifying, or compiling the source code or a
> build, you are accepting these terms. The source code, just like the compiled
> software, is given to you for free, but without any warranty. It is not
> guaranteed to work, and the developer is not responsible for any damages from
> the use of the software. You are allowed to make any modifications, and
> release them for free under this licence. If you release a modified version,
> you have to link this repository as its source. You are not allowed to sell
> any part of the original or the modified version. You are also not allowed to
> show advertisements in the modified software. The software must be named with
> a link to the creator (http://en.sbence.hu) when used in public (e.g. for
> screenings) or commercially (e.g. as an API in another software), also, the
> original creator's permission is required for public use (e.g. screening). If
> you include these code or any part of the original version in any other
> project, these terms still apply.

---

## truehdd

**Used by:** the Jellyfin plugin only, as an external subprocess (see
`JellyfinPlugin/README.md`) — decodes the object audio out of a TrueHD Atmos
track. The plugin's build (`JellyfinPlugin/truehdd/build.sh`) pins a specific
upstream commit and applies a small patch,
`JellyfinPlugin/truehdd/audio-stdout.patch`: upstream truehdd only writes
object audio to a CAF file (seeking back at the end to fill in the length,
which means it can't be read until the whole decode finishes); the patch adds
a `decode --audio-stdout` flag that streams the same samples to stdout as raw
24-bit little-endian PCM instead, which is what makes the plugin's live,
seek-anywhere decoding possible. The DAMF header and metadata are unaffected —
upstream already flushes those after every update. Per Apache-2.0 §4, this is
noted here as a modification to the original work; the patch is small,
self-contained, and offered upstream as a candidate contribution.

- Project: <https://github.com/truehdd/truehdd>
- Licence: Apache License 2.0 (full text in the shared [Appendix](#appendix-apache-license-20) below)

---

## Depth Anything V2 (Small)

**Used by:** the Convolution app (`Pseudo3DVideoPlayerView` / `CoreMLDepthProvider`
and the offline `DepthConverter` pipeline) for monocular depth estimation
driving the 2D→3D "fake 3D" video conversion. Distributed as Core ML
`.mlpackage`/`.mlmodelc` models, either bundled with the repo
(`DepthAnythingV2Small770x574.mlpackage`, `models/DepthAnythingV2SmallF16.mlmodelc`)
or downloaded on demand in-app from Apple's canonical Hugging Face mirror,
`apple/coreml-depth-anything-v2-small` — nothing is re-hosted.
`scripts/convert-depth-model.py` converts the same architecture at other
resolutions/variants from the original PyTorch weights.

- Original project: <https://github.com/DepthAnything/Depth-Anything-V2>
- Apple's Core ML port: <https://huggingface.co/apple/coreml-depth-anything-v2-small>
- Licence: Apache License 2.0 (full text in the shared [Appendix](#appendix-apache-license-20) below) — **Small only.**

**Important — do not substitute Base or Large:** Depth Anything V2's upstream
project licenses the **Small** variant under Apache 2.0, but the **Base** and
**Large** variants under a CC-BY-NC (non-commercial) licence, because they're
derived from a differently-licensed pretrained backbone. `models/DepthAnythingV2BaseF16.mlmodelc`
exists in this repo for local experimentation only and must not ship in any
distributed build, and `convert-depth-model.py --variant base`/`large` must
carry the same restriction if their output is ever distributed. Convolution's
in-app downloader (`DepthModelManagerSheet`) only offers Small variants for
exactly this reason.

---

## Jellyfin.Controller / Jellyfin.Model (compile-time only, not distributed)

**Used by:** the Jellyfin plugin project, as `PackageReference`s marked
`ExcludeAssets="runtime"` in `Jellyfin.Plugin.AtmosObjects.csproj` — they
provide the server's own types to compile against and are supplied by the
Jellyfin server at runtime; neither assembly is copied into the plugin's
output or distributed with it.

- Project: <https://github.com/jellyfin/jellyfin>
- Licence: GPL-3.0-only

---

## Other dependencies scanned for

- **Convolution app (Swift):** no external Swift Package Manager dependencies.
  `Hypnos.xcodeproj/project.pbxproj` has no `XCRemoteSwiftPackageReference`
  entries — every Swift package here (`RAVESDK`, `RAVEEngine`,
  `Packages/NextcloudMedia`) is a local, same-author package referenced by
  relative path (see `README.md` → Dependencies), not a third-party one.
  `Packages/NextcloudMedia/Package.swift` likewise declares no external
  dependencies.
- **Jellyfin plugin (.NET):** `Jellyfin.Plugin.AtmosObjects.csproj`'s only
  `PackageReference`s are `Jellyfin.Controller`/`Jellyfin.Model` (above,
  compile-time only) and the new `Cavern`/`Cavern.Format` (above). No other
  NuGet packages are referenced.
- **In-app acknowledgements screen:** none exists yet — Settings has no
  "Open Source Licenses"/About page. This file is currently the only place
  these notices are collected; linked from `README.md` and
  `JellyfinPlugin/README.md`.

---

## Appendix: Apache License 2.0

Covers both **truehdd** and **Depth Anything V2 (Small)** above; reproduced
once since it's the same text for both.

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```
