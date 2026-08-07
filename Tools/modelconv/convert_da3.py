"""Convert Depth Anything 3 Small to Core ML for monocular depth.

DA3 is a multi view geometry model. Its own forward runs a camera encoder, a
camera decoder, a reference view selector, an optional Gaussian splatting
branch, and a sky pass that uses torch.quantile, randint, and boolean masks with
data dependent shapes. None of that traces, and none of it is wanted here:
Relief feeds one frame and wants one depth map.

So this calls the pieces directly. Backbone with no camera token, then the depth
head, and nothing else. Same approach as the Video Depth Anything conversion.

DA3-SMALL and DA3-BASE are Apache-2.0. Large and Giant are CC-BY-NC and are
deliberately not offered here.

Usage:
    .venv/bin/python convert_da3.py [--size 504] [--model da3-small]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "da3" / "src"))

# Only the permissively licensed sizes. The others are non commercial.
PERMISSIVE = {
    "da3-small": "depth-anything/DA3-SMALL",
    "da3-base": "depth-anything/DA3-BASE",
}


class MonocularDA3(torch.nn.Module):
    """One frame in, one inverse depth map out.

    Wraps the network so the traced graph contains the backbone and the depth
    head and nothing else. Shapes are pinned, for the same reason they are
    pinned in the video model conversion: read off a tensor they become one
    element arrays and the converter stops at the int() cast.
    """

    MEAN = [0.485, 0.456, 0.406]
    STD = [0.229, 0.224, 0.225]

    def __init__(self, net, size: int):
        super().__init__()
        self.net = net
        self.size = size
        self.register_buffer("mean", torch.tensor(self.MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(self.STD).view(1, 3, 1, 1))

    def forward(self, image):
        # image: [1, 3, H, W] in 0...1
        x = (image - self.mean) / self.std
        # The network wants [B, N, 3, H, W]. One view.
        x = x.unsqueeze(1)

        feats, _ = self.net.backbone(x, cam_token=None, export_feat_layers=[])
        output = self.net._process_depth_head(feats, self.size, self.size)

        depth = output["depth"] if isinstance(output, dict) else output.depth
        # Collapse the batch and view dimensions to a plain [1, H, W] map.
        return depth.reshape(1, self.size, self.size)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="da3-small", choices=sorted(PERMISSIVE))
    parser.add_argument("--size", type=int, default=504)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    if args.size % 14 != 0:
        raise SystemExit(f"--size must be a multiple of 14, got {args.size}")

    from depth_anything_3.api import DepthAnything3

    repo = PERMISSIVE[args.model]
    print(f"Loading {repo} ({args.model}, Apache-2.0)")
    model = DepthAnything3.from_pretrained(repo)
    model.eval()

    wrapper = MonocularDA3(model.model, args.size).eval()
    example = torch.rand(1, 3, args.size, args.size)

    print("Warming up...", flush=True)
    with torch.no_grad():
        reference = wrapper(example)
    print(f"  output {tuple(reference.shape)}", flush=True)

    print("Tracing...", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)
        traced_out = traced(example)
    delta = (reference - traced_out).abs().max().item()
    print(f"  trace vs eager max delta: {delta:.6f}", flush=True)
    if delta > 1e-3:
        raise SystemExit("traced graph disagrees with the eager model")

    import coremltools as ct

    # Same one element shape tolerance the video model needed.
    from convert_vda import patch_coremltools_scalar_cast
    patch_coremltools_scalar_cast()

    print("Converting to Core ML...", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, args.size, args.size), dtype=np.float32)],
        outputs=[ct.TensorType(name="depth", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )

    mlmodel.short_description = (
        f"Depth Anything 3 ({args.model}) monocular inverse depth. Higher is closer."
    )
    mlmodel.input_description["image"] = f"One RGB frame, 0 to 1, [1, 3, {args.size}, {args.size}]"
    mlmodel.output_description["depth"] = f"Inverse depth, [1, {args.size}, {args.size}]"

    name = args.out or f"DepthAnything3{args.model.split('-')[1].capitalize()}.mlpackage"
    out = HERE / name
    mlmodel.save(str(out))
    print(f"Saved {out}", flush=True)

    print("Checking against PyTorch...", flush=True)
    loaded = ct.models.MLModel(str(out))
    result = loaded.predict({"image": example.numpy().astype(np.float32)})
    depth = np.asarray(result["depth"])

    flat_ct = depth.reshape(-1).astype(np.float64)
    flat_pt = reference.numpy().reshape(-1).astype(np.float64)
    correlation = np.corrcoef(flat_ct, flat_pt)[0, 1]
    print(f"  output shape {depth.shape}")
    print(f"  correlation with PyTorch: {correlation:.6f}")
    if correlation < 0.99:
        raise SystemExit("the converted model does not agree with PyTorch")


if __name__ == "__main__":
    main()
