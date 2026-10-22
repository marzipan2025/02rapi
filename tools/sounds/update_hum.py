"""업데이트 설치 중 허밍 루프 합성 → update_hum.wav

A2(110) + E3(165) 완전5도 + 느린 맥놀이. 앱의 포털 점멸(2.8초, smoothstep 호흡)과
같은 곡선으로 커졌다 작아지고, 14초 = 2.8초 × 5 라 끊김 없이 반복된다.

루프 이음새가 안 들리도록 모든 주파수 × 14초가 정수가 되게 맞췄다
(맥놀이용 어긋난 음: 110.8 → 110+5/7, 165.6 → 165+4/7).
페이드 인/아웃은 파일에 넣지 않고 앱에서 처리한다.

사용: python3 tools/sounds/update_hum.py 02rapi/02rapi
      (두 번째 인자를 주면 이음새 확인용 loop_x2_preview.wav 도 만든다)
"""
import math, struct, sys, wave

SR = 44100
PERIOD = 2.8
DUR = PERIOD * 5
N = round(SR * DUR)
TAU = 2 * math.pi
out_dir = sys.argv[1]
PEAK = 0.35 / 2  # 처음 후보(피크 0.35)의 절반

FREQS = [(110, 1.0), (110 + 5 / 7, 1.0), (165, 0.8), (165 + 4 / 7, 0.8), (220, 0.15)]


def breath(t):
    w = (1 - math.cos(TAU * t / PERIOD)) / 2
    return w * w * (3 - 2 * w)


raw = []
for i in range(N):
    t = i / SR
    v = sum(a * math.sin(TAU * f * t) for f, a in FREQS)
    raw.append(v * (0.08 + 0.92 * breath(t)))
k = PEAK / max(abs(s) for s in raw)
frames = b"".join(struct.pack("<h", int(s * k * 32767)) for s in raw)


def write(name, data):
    with wave.open(f"{out_dir}/{name}", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)


write("update_hum.wav", frames)
if len(sys.argv) > 2:
    write("loop_x2_preview.wav", frames * 2)  # 이음새 확인용 (2회 연속)
print(N, "samples")
