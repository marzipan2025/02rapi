#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 소리원 블러를 한 번에 그린다. 픽셀마다 블러 장(場)을 float 로 직접 계산하고,
// 볼록렌즈 굴절·색수차도 그 장을 굴절된 위치에서 다시 계산해 얻는다.
//
// 예전에는 13×13 메시 그라데이션을 8비트 레이어에 그린 뒤 그 레이어를 렌즈 셰이더가 다시 읽었다.
// 완만한 색 변화가 8비트(프리멀티플라이드, 알파 ≤ 0.59)로 두 번 깎이고 렌즈가 1.4배로 늘려,
// 어두운 바탕에서 등고선 같은 계단이 보였다. 이제 중간 텍스처가 없고, 마지막 8비트 양자화도
// 디더링으로 흩는다.
//
// blobs: 블러마다 [중심 x, 중심 y, 지름, 선형 R, G, B] 6개씩.

constant int kBlobStride = 6;

struct Field {
    float3 rgb;   // 선형 sRGB (언프리멀티플라이드)
    float alpha;
};

// min(w, 1) 을 부드럽게: 블러가 겹쳐 가중치 합이 1 을 넘는 경계에서 꺾인 주름이 생기지 않게.
static float softSaturate(float w) {
    const float k = 0.25;
    float h = clamp(0.5 + 0.5 * (1.0 - w) / k, 0.0, 1.0);
    return mix(1.0, w, h) - k * h * (1.0 - h);
}

//  · 불투명도 = 블러들의 가우시안 가중치 합 → 크고 가까운 블러일수록 넓고 진하게 (볼륨·좌우 인지)
//  · 색 = "자기 반지름 대비 거리"의 역세제곱 가중 평균 → 각 블러 중심 근처는 반드시 자기 색이고,
//    큰 블러가 작은 블러를 덮지 못한 채 경계에서만 섞인다.
static Field evalField(float2 p, device const float *blobs, int count) {
    float w = 0.0;
    float hueW = 0.0;
    float3 rgb = float3(0.0);
    for (int i = 0; i + kBlobStride <= count; i += kBlobStride) {
        float2 c = float2(blobs[i], blobs[i + 1]);
        float diameter = blobs[i + 2];
        float sigma = diameter * 0.4;
        float dd = distance(p, c);
        w += exp(-(dd * dd) / (2.0 * sigma * sigma));

        float rel = max(dd / (diameter * 0.5), 0.05);
        float hi = 1.0 / (rel * rel * rel);
        hueW += hi;
        rgb += hi * float3(blobs[i + 3], blobs[i + 4], blobs[i + 5]);
    }
    Field f;
    f.rgb = hueW > 0.0 ? rgb / hueW : float3(0.0);
    f.alpha = softSaturate(w) * 0.59;
    return f;
}

static float3 linearToSRGB(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

// 픽셀마다 독립인 0…1 난수 (PCG 정수 해시). 좌표를 실수 그대로 섞는 해시는 무늬(동심원)가 남는다.
static float pixelNoise(uint2 q, uint salt) {
    uint v = q.x * 1973u + q.y * 9277u + salt * 26699u;
    v = v * 747796405u + 2891336453u;
    v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    v = (v >> 22u) ^ v;
    return float(v) * (1.0 / 4294967296.0);
}

static float2 insideCircle(float2 p, float2 center, float limit) {
    float2 d = p - center;
    float len = length(d);
    return len > limit ? center + d * (limit / len) : p;
}

[[ stitchable ]] half4 blobField(float2 position, half4 color,
                                 float2 center, float radius,
                                 float strength, float aberration,
                                 device const float *blobs, int count) {
    float2 d = position - center;
    float len = length(d);
    // 원 경계 안티앨리어싱 (레티나 기준 약 1px)
    float coverage = clamp((radius - len) * 2.0 + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) {
        return half4(0.0h);
    }
    float r = min(len / radius, 1.0);

    // 볼록렌즈: 중심일수록 샘플을 중심 쪽에서 가져와 확대 (가장자리에서 1배로 연속, 중심 약 1.4배)
    float k = 1.0 - strength * (1.0 - r * r);
    float2 base = center + d * k;
    // 색수차: 가장자리에서 가장 크지만 안쪽에서도 30% 는 남겨, 원 안의 색 경계마다 무지개 테가 생기게.
    // 어긋난 샘플 위치는 원 안으로 제한한다 (원 밖은 블러가 잘린 곳이라 R/B 만 빠지면 테두리에 선이 생긴다).
    float2 dir = len > 0.0 ? d / len : float2(0.0);
    float2 shift = dir * radius * aberration * (0.3 + 0.7 * r);
    float limit = radius - 1.0;

    Field c = evalField(base, blobs, count);
    Field cr = evalField(insideCircle(base + shift, center, limit), blobs, count);
    Field cb = evalField(insideCircle(base - shift, center, limit), blobs, count);

    float alpha = c.alpha * coverage;
    float3 srgb = linearToSRGB(float3(cr.rgb.r, c.rgb.g, cb.rgb.b)) * alpha;

    // 디더링: 출력이 8비트로 깎일 때 생기는 등고선을 ±1단계 삼각분포 노이즈로 흩는다.
    // 프리멀티플라이드 값에 더하므로 바탕과 합성된 최종 색에 그대로 1단계 이내로 얹힌다.
    // position 은 포인트 단위라 4배 해 1x·2x 화면 모두 픽셀마다 다른 칸이 되게 한다.
    uint2 q = uint2(int2(floor(position * 4.0)) + 65536);
    float n = pixelNoise(q, 0u) + pixelNoise(q, 1u) - 1.0;
    srgb += n / 255.0 * min(1.0, alpha * 16.0);

    return half4(half3(clamp(srgb, 0.0, alpha)), half(alpha));
}
