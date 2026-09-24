// Final blit: sample the Oklab render target and convert to linear sRGB.
// The texture and sampler use separate descriptor sets (0 and 2).

import lib.color;

[[vk::binding(0, 0)]]
Texture2D uRenderTarget;

[[vk::binding(0, 2)]]
SamplerState uBlitSampler;

[shader("fragment")]
float4 main(float4 fragPos : SV_Position) {
    float4 oklab = uRenderTarget.Load(int3(int2(fragPos.xy), 0));
    float3 srgb = oklabToSRGB(oklab.xyz);
    return float4(srgb, 1.0);
}
