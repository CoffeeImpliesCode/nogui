// Blit pass: sample the Oklab render target, convert to linear sRGB
// (ported from blit_oklab.frag). Separate texture + sampler descriptors
// (set 0 = image, set 2 = sampler) — the heap binds all sets once.

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
