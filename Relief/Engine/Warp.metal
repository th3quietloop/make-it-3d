#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types

struct WarpUniforms {
    float2 frameSize;      // output frame size in pixels
    float  eyeFactor;      // +0.5 for the left eye, -0.5 for the right
    float  overscan;       // 0.025 means scale by 1.025 and crop to frame
};

struct UpsampleUniforms {
    uint2  lowSize;        // disparity map size, the model's output resolution
    uint2  highSize;       // frame size
    float  spatialSigma;   // in low resolution pixels
    float  lumaSigma;      // in 0...1 luma units
};

struct WarpVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

// MARK: - Joint bilateral upsampling
//
// The depth model works at 518x392. Scaling that straight up with a bilinear
// filter leaves soft halos wherever a depth edge does not line up with an image
// edge, which is the "shimmer at hair and fences" the golden set scores against.
// Weighting each low resolution depth sample by how close its guide luma is to
// the output pixel's luma snaps the depth edge onto the real image edge.

kernel void jointBilateralUpsample(
    texture2d<float, access::read>  lowDisparity [[texture(0)]],
    texture2d<float, access::sample> guide       [[texture(1)]],
    texture2d<float, access::write> highDisparity[[texture(2)]],
    constant UpsampleUniforms &u                 [[buffer(0)]],
    uint2 gid                                    [[thread_position_in_grid]])
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
    // at the ratios this pipeline uses.
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            const float2 tap = lowBase + float2(dx, dy);
            const int2 clamped = int2(clamp(tap, float2(0.0), lowSize - 1.0));

            const float disparity = lowDisparity.read(uint2(clamped)).r;

            // Guide luma sampled where this low resolution tap sits in the
            // full resolution frame.
            const float2 tapUV = (float2(clamped) + 0.5) / lowSize;
            const float tapLuma = guide.sample(guideSampler, tapUV).r;

            const float2 spatialDelta = tap - lowPos;
            const float spatialDistanceSquared = dot(spatialDelta, spatialDelta);
            const float lumaDelta = tapLuma - centreLuma;

            const float weight =
                exp(-spatialDistanceSquared / spatialDenom) *
                exp(-(lumaDelta * lumaDelta) / lumaDenom);

            weightedSum += disparity * weight;
            weightTotal += weight;
        }
    }

    const float result = weightTotal > 1e-6 ? (weightedSum / weightTotal) : 0.0;
    highDisparity.write(float4(result, 0.0, 0.0, 0.0), gid);
}

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
    return out;
}

fragment float4 warpFragment(
    WarpVertexOut in                          [[stage_in]],
    texture2d<float, access::sample> source   [[texture(0)]])
{
    constexpr sampler sourceSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    return float4(source.sample(sourceSampler, in.texcoord).rgb, 1.0);
}

// MARK: - Depth visualisation
//
// The silver ramp from the design file. Explicitly not turbo or viridis.

struct RampUniforms {
    float3 nearColour;
    float3 farColour;
    float  minDisparity;
    float  maxDisparity;
};

kernel void depthRamp(
    texture2d<float, access::read>  disparity [[texture(0)]],
    texture2d<float, access::write> output    [[texture(1)]],
    constant RampUniforms &u                  [[buffer(0)]],
    uint2 gid                                 [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    // Read by pixel rather than sampling by normalized coordinate. The
    // disparity texture and the output are the same size here, so a direct
    // read is both exact and cheaper, and it removes any question about how
    // the sampler maps coordinates between them.
    const float d = disparity.read(gid).r;
    const float range = max(u.maxDisparity - u.minDisparity, 1e-5);
    const float t = clamp((d - u.minDisparity) / range, 0.0, 1.0);

    const float3 colour = mix(u.farColour, u.nearColour, t);
    output.write(float4(colour, 1.0), gid);
}

// MARK: - Anaglyph
//
// Half colour anaglyph for the Stereo preview: red channel from the left view,
// green and blue from the right.

kernel void anaglyph(
    texture2d<float, access::read>  left   [[texture(0)]],
    texture2d<float, access::read>  right  [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    const float4 l = left.read(gid);
    const float4 r = right.read(gid);
    output.write(float4(l.r, r.g, r.b, 1.0), gid);
}
