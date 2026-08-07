"""Convert Video Depth Anything Small to Core ML.

Make It 3D estimates depth one frame at a time and then smooths the results with a
running average. That smoothing is a patch. Video Depth Anything handles time
inside the model, which is the actual fix for depth that pumps across a shot.

Nobody had converted it to Core ML, so this does. The risky part is the
temporal head: four motion modules that attend across the frame window. If they
trace, the rest is ordinary DPT.

Apache-2.0, both the code and the Small weights.

Usage:
    .venv/bin/python convert_vda.py [--frames 32] [--size 518]
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "vda"))

from video_depth_anything.video_depth import VideoDepthAnything  # noqa: E402


ENCODER_CONFIG = {
    "vits": {"encoder": "vits", "features": 64, "out_channels": [48, 96, 192, 384]},
}


def patch_for_tracing(frames: int):
    """Make the dynamic shape reads static.

    The model is written to accept any frame count, so it reads lengths off the
    tensors as it goes. Under torch.jit.trace those reads become tensors rather
    than plain integers, and coremltools then hits an int() cast on something
    that is not a scalar and gives up.

    We are converting for one fixed window size, so every one of these lengths
    is a known constant. Pinning them removes the dynamic reads without
    changing what the model computes.
    """
    import torch.nn.functional as F
    from video_depth_anything.motion_module import motion_module as mm
    from video_depth_anything import dpt_temporal

    # `self.pe[:, :x.size(1)]` is one such cast. With the window pinned to the
    # module's own max_len, the slice is a no op.
    def positional_forward(self, x):
        return self.dropout(x + self.pe.to(x.dtype))

    mm.PositionalEncoding.forward = positional_forward

    # The DPT head reads the batch size and the intermediate resolutions off
    # the tensors as it goes. All of them are fixed once the window and the
    # input size are fixed, so the head runs once eagerly to record them and
    # then uses the recorded literals. Same arithmetic, no shape reads in the
    # traced graph.
    original_forward = dpt_temporal.DPTHeadTemporal.forward

    def recording_forward(
        self, out_features, patch_h, patch_w, frame_length,
        micro_batch_size=4, cached_hidden_state_list=None
    ):
        sizes = getattr(self, "_relief_sizes", None)

        out = []
        for i, x in enumerate(out_features):
            x = x[0]
            channels = self.projects[i].in_channels
            x = x.permute(0, 2, 1).reshape(
                (frame_length, channels, patch_h, patch_w)
            ).contiguous()
            x = self.projects[i](x)
            x = self.resize_layers[i](x)
            out.append(x)

        layer_1, layer_2, layer_3, layer_4 = out

        if sizes is None:
            sizes = {
                "l1": tuple(int(v) for v in layer_1.shape[2:]),
                "l2": tuple(int(v) for v in layer_2.shape[2:]),
                "l3": tuple(int(v) for v in layer_3.shape[2:]),
            }
            self._relief_sizes = sizes

        # B is always 1 here: the window is a single clip.
        shape = (1, frame_length)

        layer_3, h0 = self.motion_modules[0](
            layer_3.unflatten(0, shape).permute(0, 2, 1, 3, 4), None, None, None
        )
        layer_3 = layer_3.permute(0, 2, 1, 3, 4).flatten(0, 1)
        layer_4, h1 = self.motion_modules[1](
            layer_4.unflatten(0, shape).permute(0, 2, 1, 3, 4), None, None, None
        )
        layer_4 = layer_4.permute(0, 2, 1, 3, 4).flatten(0, 1)

        layer_1_rn = self.scratch.layer1_rn(layer_1)
        layer_2_rn = self.scratch.layer2_rn(layer_2)
        layer_3_rn = self.scratch.layer3_rn(layer_3)
        layer_4_rn = self.scratch.layer4_rn(layer_4)

        path_4 = self.scratch.refinenet4(layer_4_rn, size=sizes["l3"])
        path_4, h2 = self.motion_modules[2](
            path_4.unflatten(0, shape).permute(0, 2, 1, 3, 4), None, None, None
        )
        path_4 = path_4.permute(0, 2, 1, 3, 4).flatten(0, 1)

        path_3 = self.scratch.refinenet3(path_4, layer_3_rn, size=sizes["l2"])
        path_3, h3 = self.motion_modules[3](
            path_3.unflatten(0, shape).permute(0, 2, 1, 3, 4), None, None, None
        )
        path_3 = path_3.permute(0, 2, 1, 3, 4).flatten(0, 1)

        path_2 = self.scratch.refinenet2(path_3, layer_2_rn, size=sizes["l1"])
        path_1 = self.scratch.refinenet1(path_2, layer_1_rn)

        output = self.scratch.output_conv1(path_1)
        output = F.interpolate(
            output, (patch_h * 14, patch_w * 14), mode="bilinear", align_corners=True
        )
        output = self.scratch.output_conv2(output)
        return output, h0 + h1 + h2 + h3

    dpt_temporal.DPTHeadTemporal.forward = recording_forward
    print(f"  patched the temporal head for a fixed {frames} frame window")
    return original_forward


def patch_coremltools_scalar_cast():
    """Let a one element array satisfy an int() cast.

    coremltools converts `aten::Int` by calling Python's int() on the value.
    When a traced graph carries a length as a shape (1,) array rather than a
    true scalar, that raises, and the conversion stops on what is really a
    representation detail: a one element array holding 37 and the integer 37
    mean the same thing to every op downstream.

    This unwraps exactly that case and nothing else. An array with more than
    one element still raises, because that would be a genuine problem rather
    than a shape quirk.
    """
    import numpy as _np
    from coremltools.converters.mil.frontend.torch import ops

    original = ops._cast

    def tolerant_cast(context, node, dtype, dtype_str):
        try:
            return original(context, node, dtype, dtype_str)
        except TypeError:
            value = context[node.inputs[0]]
            raw = getattr(value, "val", None)
            if isinstance(raw, _np.ndarray) and raw.size == 1:
                from coremltools.converters.mil import Builder as mb
                result = mb.const(val=dtype(raw.reshape(-1)[0]), name=node.name)
                context.add(result)
                return result
            raise

    ops._cast = tolerant_cast
    print("  patched the coremltools scalar cast for one element shapes")


class TracedVDA(torch.nn.Module):
    """Trace friendly wrapper.

    Two jobs. It pins the frame count so the temporal attention sees a fixed
    window, and it normalizes inside the graph so Swift can hand over plain
    0 to 1 image data instead of reimplementing ImageNet statistics.
    """

    MEAN = [0.485, 0.456, 0.406]
    STD = [0.229, 0.224, 0.225]

    def __init__(self, model: VideoDepthAnything, frames: int, size: int):
        super().__init__()
        self.model = model
        self.frames = frames
        self.size = size
        # 14px patches. Computed here as a Python int rather than read off the
        # tensor, which is the whole point of this wrapper.
        self.patch = size // 14
        self.register_buffer("mean", torch.tensor(self.MEAN).view(1, 1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(self.STD).view(1, 1, 3, 1, 1))

    def forward(self, frames):
        """The model's own forward, with every shape read replaced by a constant.

        The original does `B, T, C, H, W = x.shape` and then `H // 14`. Under a
        trace those become tensors, so the patch count arrives at the DPT head
        as a one element array instead of an integer, and coremltools stops at
        the int() cast. Everything here is known ahead of time, so it is spelled
        out instead of measured.
        """
        x = (frames - self.mean) / self.std
        x = x.flatten(0, 1)                       # [T, 3, H, W]

        features = self.model.pretrained.get_intermediate_layers(
            x,
            self.model.intermediate_layer_idx[self.model.encoder],
            return_class_token=True,
        )
        depth = self.model.head(features, self.patch, self.patch, self.frames)[0]
        depth = torch.nn.functional.interpolate(
            depth, size=(self.size, self.size), mode="bilinear", align_corners=True
        )
        depth = torch.nn.functional.relu(depth)
        return depth.squeeze(1).unflatten(0, (1, self.frames))  # [1, T, H, W]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=32)
    parser.add_argument("--size", type=int, default=518)
    parser.add_argument("--out", type=str, default="VideoDepthAnythingSmall.mlpackage")
    parser.add_argument(
        "--weights", type=str, default="weights/video_depth_anything_vits.pth"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help=(
            "Load and run the saved model to compare it against PyTorch. Off by "
            "default because compiling a graph this size takes far longer than "
            "converting it, and the artifact is worth writing to disk first."
        ),
    )
    args = parser.parse_args()

    # The patch grid is 14px, so the input has to divide by 14 cleanly.
    if args.size % 14 != 0:
        raise SystemExit(f"--size must be a multiple of 14, got {args.size}")

    patch_for_tracing(args.frames)

    print(f"Building vits at {args.frames} frames of {args.size}x{args.size}")
    model = VideoDepthAnything(**ENCODER_CONFIG["vits"], num_frames=args.frames)

    state = torch.load(args.weights, map_location="cpu")
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing:
        print(f"  missing keys: {len(missing)} (first few: {missing[:3]})")
    if unexpected:
        print(f"  unexpected keys: {len(unexpected)} (first few: {unexpected[:3]})")

    model.eval()
    wrapper = TracedVDA(model, args.frames, args.size).eval()

    example = torch.rand(1, args.frames, 3, args.size, args.size)

    # Warm up eagerly first. This is what records the intermediate resolutions
    # the patched head then uses as literals, so the trace never sees a shape
    # read at all.
    #
    # Each of these passes is a ViT over 32 images on the CPU and takes minutes.
    # They are the expensive part of this script by a wide margin: the Core ML
    # conversion itself is seconds.
    print("Warming up to record the fixed shapes...")
    with torch.no_grad():
        eager_out = wrapper(example)
    print(f"  output {tuple(eager_out.shape)}", flush=True)

    print("Tracing...", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)
    print("  traced", flush=True)

    # Sanity: the traced graph has to agree with the eager model, otherwise the
    # trace captured the wrong branch somewhere.
    with torch.no_grad():
        traced_out = traced(example)
    delta = (eager_out - traced_out).abs().max().item()
    print(f"  trace vs eager max delta: {delta:.6f}", flush=True)
    if delta > 1e-3:
        raise SystemExit("traced graph disagrees with the eager model")

    # Hand the reference output to the Core ML check below, so the saved model
    # is compared against real numbers rather than only inspected for shape.
    reference = eager_out.numpy()

    import coremltools as ct

    patch_coremltools_scalar_cast()

    print("Converting to Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="frames",
                shape=(1, args.frames, 3, args.size, args.size),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="depth", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
        # Do not compile on the way out. Converting this graph takes seconds;
        # compiling it takes far longer, and if the process is interrupted
        # during that step the package never reaches disk at all. Write the
        # artifact first, verify it second.
        skip_model_load=not args.verify,
    )

    mlmodel.short_description = (
        "Video Depth Anything Small. Temporally consistent relative inverse "
        "depth over a fixed window of frames."
    )
    mlmodel.input_description["frames"] = (
        f"{args.frames} RGB frames, 0 to 1, shape [1, {args.frames}, 3, "
        f"{args.size}, {args.size}]"
    )
    mlmodel.output_description["depth"] = (
        f"Inverse depth per frame, shape [1, {args.frames}, {args.size}, {args.size}]. "
        "Higher is closer."
    )

    out = HERE / args.out
    mlmodel.save(str(out))
    print(f"Saved {out}", flush=True)

    # Prove the saved model runs and agrees with PyTorch. Shape alone would not
    # catch a graph that converted cleanly and computes the wrong thing.
    if not args.verify:
        size_mb = sum(f.stat().st_size for f in out.rglob("*") if f.is_file()) / (1024 * 1024)
        print(f"  package size {size_mb:.1f} MB")
        print("Re-run with --verify to check it against PyTorch.")
        return

    print("Checking the saved model against PyTorch...", flush=True)
    loaded = ct.models.MLModel(str(out))
    result = loaded.predict({"frames": example.numpy().astype(np.float32)})
    depth = np.asarray(result["depth"])
    print(f"  output shape {depth.shape}, range {depth.min():.4f} to {depth.max():.4f}")

    # Float16 compute, so exact equality is not the bar. Correlation is: the
    # depth has to rank the scene the same way PyTorch does.
    flat_ct = depth.reshape(-1).astype(np.float64)
    flat_pt = reference.reshape(-1).astype(np.float64)
    correlation = np.corrcoef(flat_ct, flat_pt)[0, 1]
    spread = flat_pt.max() - flat_pt.min()
    relative_error = np.abs(flat_ct - flat_pt).mean() / max(spread, 1e-6)
    print(f"  correlation with PyTorch: {correlation:.6f}")
    print(f"  mean absolute error: {relative_error * 100:.3f}% of range")
    if correlation < 0.99:
        raise SystemExit("the converted model does not agree with PyTorch")

    size_mb = sum(
        f.stat().st_size for f in out.rglob("*") if f.is_file()
    ) / (1024 * 1024)
    print(f"  package size {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
