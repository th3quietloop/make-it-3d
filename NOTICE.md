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

The conversion scripts that produced both packages are in `Tools/modelconv/`. Nobody had
published a Core ML conversion of Video Depth Anything when this was written, so that script
is original work and is covered by this repository's MIT licence.

## Apache License 2.0

The full text is available at https://www.apache.org/licenses/LICENSE-2.0 and is reproduced
in `Tools/modelconv/vda/LICENSE` and `Tools/modelconv/da3/LICENSE` in this repository.
