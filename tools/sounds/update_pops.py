"""Update / Updated 등장음 합성 → update_pop.wav, updated_pop.wav

허밍(A2/E3, A장조 5도)과 어울리는 부드러운 말렛 (둥근 사인 + 약한 배음).
  Update  = 아래에서 튀어오름 → 짧은 블립 + 올라가는 두 음 (A4 → E5)
  Updated = 완료 → A장조 화음으로 해결되는 세 음 (A4 → C#5 → E5 + A5)
음량은 처음 후보(피크 0.3)의 85%.

사용: python3 tools/sounds/update_pops.py 02rapi/02rapi
"""
import math, struct, sys, wave

SR = 44100
TAU = 2 * math.pi
PEAK = 0.3 * 0.85
out_dir = sys.argv[1]
A4, CS5, E5, A5 = 440.0, 554.37, 659.25, 880.0


def mallet(f, dt):
    if dt < 0:
        return 0.0
    atk = min(1.0, dt / 0.004)
    return atk * (math.exp(-dt / 0.22) * math.sin(TAU * f * dt)
                  + 0.25 * math.exp(-dt / 0.08) * math.sin(TAU * 2 * f * dt))


def blip(dt, f0, f1, dur):
    """튀어오르는 느낌: 짧게 위로 미끄러지는 사인"""
    if dt < 0 or dt > dur + 0.3:
        return 0.0
    k = min(dt / dur, 1.0)
    f = f0 * (f1 / f0) ** (k * k * (3 - 2 * k))
    # 위상은 주파수 적분 근사 (짧아서 충분)
    phase = TAU * (f0 * dt + (f - f0) * dt / 2)
    atk = min(1.0, dt / 0.005)
    return atk * math.exp(-dt / 0.12) * math.sin(phase)


def render(name, notes, length, glide=None):
    n = int(SR * length)
    s = []
    for i in range(n):
        t = i / SR
        v = sum(a * mallet(f, t - at) for at, f, a in notes)
        if glide:
            v += glide(t)
        fade = min(1.0, (length - t) / 0.15)
        s.append(v * fade)
    m = max(abs(x) for x in s) or 1
    with wave.open(f"{out_dir}/{name}", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(x * PEAK / m * 32767)) for x in s))


render("update_pop.wav", [(0.03, A4, 1.0), (0.11, E5, 0.8)], 0.9,
       glide=lambda t: 0.35 * blip(t, 330, 660, 0.06))
render("updated_pop.wav", [(0.0, A4, 0.9), (0.09, CS5, 0.8), (0.18, E5, 0.9), (0.18, A5, 0.3)], 1.2)
print("done")
