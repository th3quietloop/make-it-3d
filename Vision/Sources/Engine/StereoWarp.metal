#include <metal_stdlib>
using namespace metal;

// The stereo synthesis, ported from the Mac app's MakeIt3D/Engine/Warp.metal.
//
// Two things changed on the way across, and neither of them is the warp:
//
//   1. Depth arrives as a texture off a video track rather than as a float
//      array off a model, so the upsample reads an 8 bit luma level and maps it
//      back into the film's shared nearness space with the shot's scale and
//      offset.
//
//   2. Nearness to disparity is its own pass. On the Mac that mapping happened
//      on the CPU once per frame, because S and C were fixed for the whole
//      conversion. Here they move while the film plays, so the expensive part
//      (the guided upsample) runs once per video frame and the cheap part runs
//      again every time the dial does.
//
// The warp itself is unchanged, deliberately. It is the part that is known to
// be right.

// MARK: - Shared types

struct WarpUniforms {
    float2 frameSize;      // output frame size in pixels
    float  eyeFactor;      // how much of the disparity this eye carries
    float  overscan;       // 0.025 means scale by 1.025 and crop to frame
    float  vertexStep;     // grid spacing in normalized source coordinates
    float  stretchLimit;   // discard fragments stretched beyond this factor
};

struct PlateUniforms {
    float  backgroundLevel; // disparity at or below this counts as background
    float  blend;           // how fast fresh background replaces the plate
};

struct UpsampleUniforms {
    uint2  lowSize;        // depth track size, half the frame
    uint2  highSize;       // frame size
    float  spatialSigma;   // in low resolution pixels
    float  lumaSigma;      // in 0...1 luma units
    float  depthScale;     // this shot's scale back into the shared space
    float  depthOffset;    // this shot's offset back into the shared space
};

struct DisparityUniforms {
    float  gain;           // S * frame width, in pixels
    float  convergence;    // C, the nearness that lands on the screen plane
    float  forwardPopScale;// positive disparity is scaled by this
};

struct WarpVertexOut {
    float4 position [[position]];
    float2 texcoord;
    // How far this triangle got pulled horizontally. 1 is untouched, above 1
    // is stretched across a disocclusion, below 1 is compressed by an overlap.
    float  stretch;
};

// MARK: - Luma extraction
//
// The guide for the bilateral upsample. Rec. 709 luma from the BGRA frame.

kernel void extractLuma(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> luma   [[texture(1)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) { return; }
    const float4 colour = source.read(gid);
    const float value = dot(colour.rgb, float3(0.2126, 0.7152, 0.0722));
    luma.write(float4(value, 0.0, 0.0, 0.0), gid);
}

// MARK: - Joint bilateral upsampling
//
// The depth track is half resolution. Scaling that straight up with a bilinear
// filter leaves soft halos wherever a depth edge does not line up with an image
// edge, which is the shimmer at hair and fences. Weighting each low resolution
// depth sample by how close its guide luma is to the output pixel's luma snaps
// the depth edge onto the real image edge.
//
// The output is nearness in the film's shared space, not a stored level, so
// everything downstream of here is working in one space across every cut.

kernel void upsampleNearness(
    texture2d<float, access::read>   lowDepth  [[texture(0)]],
    texture2d<float, access::sample> guide     [[texture(1)]],
    texture2d<float, access::write>  nearness  [[texture(2)]],
    constant UpsampleUniforms &u               [[buffer(0)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= u.highSize.x || gid.y >= u.highSize.y) { return; }

    constexpr sampler guideSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 highSize = float2(u.highSize);
    const float2 lowSize  = float2(u.lowSize);

    // Where this output pixel lands in the low resolution grid.
    const float2 uv = (float2(gid) + 0.5) / highSize;
    const float2 lowPos = uv * lowSize - 0.5;
    const float2 lowBase = floor(lowPos);

    const float centreLuma = guide.sample(guideSampler, uv).r;

    const float spatialDenom = 2.0 * u.spatialSigma * u.spatialSigma;
    const float lumaDenom    = 2.0 * u.lumaSigma * u.lumaSigma;

    float weightedSum = 0.0;
    float weightTotal = 0.0;

    // A 5x5 window in low resolution space covers the whole upsample footprint
    // at the ratio this format uses.
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            const float2 tap = lowBase + float2(dx, dy);
            const int2 clamped = int2(clamp(tap, float2(0.0), lowSize - 1.0));

            // The depth track stores 0 farthest, 255 nearest, normalized per
            // shot. An r8Unorm read hands that back as 0...1 already, so the
            // only work left is the shot's scale and offset.
            const float stored = lowDepth.read(uint2(clamped)).r;

            const float2 tapUV = (float2(clamped) + 0.5) / lowSize;
            const float tapLuma = guide.sample(guideSampler, tapUV).r;

            const float2 spatialDelta = tap - lowPos;
            const float spatialDistanceSquared = dot(spatialDelta, spatialDelta);
            const float lumaDelta = tapLuma - centreLuma;

            const float weight =
                exp(-spatialDistanceSquared / spatialDenom) *
                exp(-(lumaDelta * lumaDelta) / lumaDenom);

            weightedSum += stored * weight;
            weightTotal += weight;
        }
    }

    const float stored = weightTotal > 1e-6 ? (weightedSum / weightTotal) : 0.0;
    // Back into the film's shared depth space, so a cut does not flash.
    const float shared = stored * u.depthScale + u.depthOffset;
    nearness.write(float4(shared, 0.0, 0.0, 0.0), gid);
}

// MARK: - Nearness to disparity
//
// d = S * W * (nearness - C), which is the Mac's Disparity.field verbatim.
//
// Positive d is content in front of the screen plane, and it stays positive:
// the eye mapping convention is applied at synthesis, not folded in here.
// Folding it in was a real bug on the Mac. Negating the gain silently swapped
// which half of the field counted as in front, so the comfort scaling below got
// applied to content behind the screen. The rendered stereo still looked right,
// which is exactly why it survived.

kernel void nearnessToDisparity(
    texture2d<float, access::read>  nearness  [[texture(0)]],
    texture2d<float, access::write> disparity [[texture(1)]],
    constant DisparityUniforms &u             [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= disparity.get_width() || gid.y >= disparity.get_height()) { return; }

    float d = (nearness.read(gid).r - u.convergence) * u.gain;

    // Scale forward pop only. Content behind the screen plane keeps its full
    // disparity because it is the comfortable direction.
    if (d > 0.0) { d *= u.forwardPopScale; }

    disparity.write(float4(d, 0.0, 0.0, 0.0), gid);
}

// MARK: - Mesh warp
//
// A vertex grid over the source frame, one vertex per few pixels, with each
// vertex displaced horizontally by the disparity underneath it. Triangles that
// straddle a depth discontinuity stretch across the gap, which is what covers
// disocclusions without an inpainting pass.
//
// Disparity arrives with positive meaning in front of the screen plane. For
// such a point the left eye's copy belongs to the RIGHT of the right eye's
// copy, which is crossed disparity, so a source sample at s lands on screen at
// s + eyeFactor * d with eyeFactor positive for the left eye. The eye factor
// carries the whole convention, so flipping it is the one place the stereo
// sense can be reversed.

vertex WarpVertexOut warpVertex(
    uint vertexID                                [[vertex_id]],
    const device float2 *gridPositions           [[buffer(0)]],
    constant WarpUniforms &u                     [[buffer(1)]],
    texture2d<float, access::sample> disparity   [[texture(0)]])
{
    constexpr sampler disparitySampler(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 uv = gridPositions[vertexID];
    const float d = disparity.sample(disparitySampler, uv).r;

    // Local horizontal stretch, measured against the next grid column. Where
    // the disparity changes fast, this triangle is spanning a depth edge and
    // the pixels it draws are smeared foreground rather than real content.
    const float neighbourD = disparity.sample(
        disparitySampler, float2(min(uv.x + u.vertexStep, 1.0), uv.y)
    ).r;
    const float baseSpan = u.vertexStep * u.frameSize.x;
    const float warpedSpan = baseSpan + u.eyeFactor * (neighbourD - d);
    const float stretch = warpedSpan / max(baseSpan, 1e-5);

    float2 pixel = uv * u.frameSize;
    pixel.x += u.eyeFactor * d;

    // Overscan: scale about the frame centre and let the crop to frame hide the
    // stretched edges the warp leaves behind.
    const float2 centre = u.frameSize * 0.5;
    pixel = centre + (pixel - centre) * (1.0 + u.overscan);

    WarpVertexOut out;
    out.position = float4((pixel.x / u.frameSize.x) * 2.0 - 1.0,
                          1.0 - (pixel.y / u.frameSize.y) * 2.0,
                          0.0,
                          1.0);
    out.texcoord = uv;
    out.stretch = stretch;
    return out;
}

fragment float4 warpFragment(
    WarpVertexOut in                          [[stage_in]],
    constant WarpUniforms &u                  [[buffer(0)]],
    texture2d<float, access::sample> source   [[texture(0)]])
{
    // Drop the smear. Anything stretched past the limit is a disocclusion, and
    // whatever is already in the target (the background plate) is a better
    // answer than a foreground pixel dragged sideways to cover the gap.
    if (in.stretch > u.stretchLimit) {
        discard_fragment();
    }
    constexpr sampler sourceSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    return float4(source.sample(sourceSampler, in.texcoord).rgb, 1.0);
}

// MARK: - Background plate
//
// A running picture of what is behind the moving things.
//
// When the warp opens a gap, the content that belongs in it is usually content
// the camera already showed a moment ago, before the foreground moved across
// it. Keeping the background as it goes past means the gap can be filled with
// the real thing instead of a smear.
//
// Pixels that are far are written fresh every frame. Pixels that are near are
// left alone, so whatever background was last seen underneath them survives.

kernel void updateBackgroundPlate(
    texture2d<float, access::read>  source    [[texture(0)]],
    texture2d<float, access::read>  disparity [[texture(1)]],
    texture2d<float, access::read>  oldPlate  [[texture(2)]],
    texture2d<float, access::write> newPlate  [[texture(3)]],
    constant PlateUniforms &u                 [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= newPlate.get_width() || gid.y >= newPlate.get_height()) { return; }

    const float4 current = source.read(gid);
    const float4 stored = oldPlate.read(gid);
    const float d = disparity.read(gid).r;

    // Negative disparity is behind the screen plane, which is where background
    // lives. The further behind, the more confident we are.
    if (d <= u.backgroundLevel) {
        newPlate.write(mix(stored, current, u.blend), gid);
    } else {
        newPlate.write(stored, gid);
    }
}

kernel void seedBackgroundPlate(
    texture2d<float, access::read>  source [[texture(0)]],
    texture2d<float, access::write> plate  [[texture(1)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= plate.get_width() || gid.y >= plate.get_height()) { return; }
    plate.write(source.read(gid), gid);
}

// MARK: - Depth visualisation
//
// The silver ramp from the design file. Explicitly not turbo or viridis: the
// rainbow ramp is an AI demo tell and it is banned in this project.

struct RampUniforms {
    float3 nearColour;
    float3 farColour;
    float  minNearness;
    float  maxNearness;
};

kernel void depthRamp(
    texture2d<float, access::read>  nearness [[texture(0)]],
    texture2d<float, access::write> output   [[texture(1)]],
    constant RampUniforms &u                 [[buffer(0)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    const float n = nearness.read(gid).r;
    const float range = max(u.maxNearness - u.minNearness, 1e-5);
    const float t = clamp((n - u.minNearness) / range, 0.0, 1.0);

    output.write(float4(mix(u.farColour, u.nearColour, t), 1.0), gid);
}
