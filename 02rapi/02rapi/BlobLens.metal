#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 소리원 블러 레이어를 볼록렌즈처럼 굴절시킨다.
//  · 중심일수록 샘플을 중심 쪽에서 가져와 확대 (가장자리에서 1배로 연속)
//  · 가장자리로 갈수록 R/B 를 반대 방향으로 살짝 어긋나게 해 색수차
//  · 샘플 위치는 원 안으로 제한한다. 원 밖(빈 곳)을 읽으면 경계에서 R 만 빠져
//    잘린 테두리를 따라 항상 파란 선이 생긴다.
static half3 unpremultiply(half4 s) {
    return s.a > 0.0h ? s.rgb / s.a : half3(0.0h);
}

static float2 insideCircle(float2 p, float2 center, float limit) {
    float2 d = p - center;
    float len = length(d);
    return len > limit ? center + d * (limit / len) : p;
}

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
    // 색수차: 가장자리에서 가장 크지만 안쪽에서도 30% 는 남겨, 원 안의 색 경계마다 무지개 테가 생기게
    float2 dir = r > 0.0 ? d / length(d) : float2(0.0);
    float2 shift = dir * radius * aberration * (0.3 + 0.7 * r);
    float limit = radius - 1.0;

    half4 c = layer.sample(base);
    half4 cr = layer.sample(insideCircle(base + shift, center, limit));
    half4 cb = layer.sample(insideCircle(base - shift, center, limit));
    // 샘플은 프리멀티플라이드 색이다. 투명도가 다른 샘플의 채널을 그대로 섞으면
    // 안티앨리어싱된 경계 픽셀에서 색이 알파보다 커져 계단처럼 튄다 → 풀었다가 c.a 로 다시 곱한다.
    half3 rgb = half3(unpremultiply(cr).r, unpremultiply(c).g, unpremultiply(cb).b);
    return half4(rgb * c.a, c.a);
}
