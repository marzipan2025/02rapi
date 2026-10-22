#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 소리원 블러 레이어를 볼록렌즈처럼 굴절시킨다.
//  · 중심일수록 샘플을 중심 쪽에서 가져와 확대 (가장자리에서 1배로 연속)
//  · 가장자리로 갈수록 R/B 를 반대 방향으로 살짝 어긋나게 해 색수차
[[ stitchable ]] half4 blobLens(float2 position, SwiftUI::Layer layer,
                                float2 center, float radius,
                                float strength, float aberration) {
    float2 d = position - center;
    float r = length(d) / radius;
    if (r >= 1.0) {
        return layer.sample(position);
    }
    float k = 1.0 - strength * (1.0 - r * r);
    float2 base = center + d * k;
    float2 shift = d * aberration * r * r;

    half4 c = layer.sample(base);
    half4 cr = layer.sample(base + shift);
    half4 cb = layer.sample(base - shift);
    return half4(cr.r, c.g, cb.b, max(c.a, max(cr.a, cb.a)));
}
