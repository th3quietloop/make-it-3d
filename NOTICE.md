# Third party notices

Make It 3D itself is MIT licensed. See [LICENSE](LICENSE).

The app bundles two Core ML models converted from open source depth estimation research.
Both are Apache License 2.0, which permits redistribution with attribution. The converted
`.mlpackage` files in `MakeIt3D/Resources/Models/` are derivative works of the original
weights and carry the same licence.

## Depth Anything V2 Small

The per frame depth model, and the default. Shipped as `DepthAnythingV2SmallF16.mlpackage`.

- Upstream: https://github.com/DepthAnything/Depth-Anything-V2
- Licence: Apache License 2.0
- Paper: Yang et al., Depth Anything V2, 2024

## Video Depth Anything Small

The temporally stable model, offered as the Steady option. Shipped as
`VideoDepthAnythingSmall.mlpackage`.

- Upstream: https://github.com/DepthAnything/Video-Depth-Anything
- Licence: Apache License 2.0
- Paper: Chen et al., Video Depth Anything, 2025

The conversion scripts that produced both packages are in `Tools/modelconv/` and are
covered by this repository's MIT licence.

## Big Buck Bunny sample excerpt

`MakeIt3D/Resources/Samples/ForestMorning.mp4` is a six-second excerpt from *Big Buck Bunny*
(2008), the Blender Foundation Peach open movie. It is licensed separately from the app
under [Creative Commons Attribution 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).

(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org

See [sample attribution](MakeIt3D/Resources/Samples/SAMPLE_ATTRIBUTION.md) for the source,
license links, and modifications to the excerpt.

## Apache License 2.0

The full text is available at https://www.apache.org/licenses/LICENSE-2.0 and is reproduced
in `LICENSES/Apache-2.0.txt` in this repository.
