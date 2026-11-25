"""Original menu sounds for the Kingdom Hearts UI style, synthesized here (no recordings):
  move   - a soft, short crystal tick (pointer onto another entry)
  select - a bright two-note chime (a click)
  denied - a low double buzz (a refusal or an error)

Writes the companion's copies (16-bit mono WAV, played by Windows) to
companion/puppy_companion/sounds/menu_<kind>.wav, and Puppy Admin's (MP3, which Roblox
loads through getcustomasset) to assets/sounds/menu_<kind>_v1.mp3 (needs ffmpeg).
A player's own Menu_Move / Menu_Select / Menu_Denied files in PuppyAdmin/sounds are used instead.
Run: python3 tools/make_menu_sounds.py   (bump the _v names when the sounds change)
"""
import os
import subprocess
import wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAV_DIR = os.path.join(ROOT, "companion", "puppy_companion", "sounds")
MP3_DIR = os.path.join(ROOT, "assets", "sounds")
RATE = 44100


def env(n, attack, decay):
    t = np.arange(n) / RATE
    a = np.minimum(1.0, t / max(attack, 1e-4))
    return a * np.exp(-t / decay)


def tone(freq, seconds, attack=0.002, decay=0.05, partials=((1, 1.0),)):
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    wave_ = sum(amp * np.sin(2 * np.pi * freq * mult * t) for mult, amp in partials)
    return wave_ * env(n, attack, decay)


def place(buf, sig, at):
    i = int(at * RATE)
    buf[i:i + len(sig)] += sig[:max(0, len(buf) - i)]


def move():
    buf = np.zeros(int(RATE * 0.12))
    place(buf, tone(2350, 0.11, 0.001, 0.022, ((1, 1.0), (1.5, 0.35), (2.01, 0.2))), 0)
    return buf * 0.5


def select():
    buf = np.zeros(int(RATE * 0.42))
    bell = ((1, 1.0), (2.0, 0.3), (3.01, 0.12))
    place(buf, tone(1318.5, 0.35, 0.002, 0.09, bell), 0.0)    # E6
    place(buf, tone(1975.5, 0.36, 0.002, 0.12, bell), 0.065)  # B6
    place(buf, tone(3951.0, 0.2, 0.001, 0.04), 0.07)          # a little sparkle
    return buf * 0.42


def denied():
    buf = np.zeros(int(RATE * 0.34))
    for at, f in ((0.0, 196.0), (0.13, 155.6)):
        n = int(RATE * 0.12)
        t = np.arange(n) / RATE
        sq = np.sign(np.sin(2 * np.pi * f * t)) * 0.6 + np.sin(2 * np.pi * f * 2 * t) * 0.3
        place(buf, sq * env(n, 0.003, 0.06), at)
    # soften the square edges
    k = np.ones(9) / 9
    return np.convolve(buf, k, mode="same") * 0.45


def write_wav(path, sig):
    sig = np.clip(sig, -1, 1)
    fade = min(len(sig), int(RATE * 0.004))
    sig[-fade:] *= np.linspace(1, 0, fade)
    data = (sig * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)


def main():
    os.makedirs(WAV_DIR, exist_ok=True)
    os.makedirs(MP3_DIR, exist_ok=True)
    for kind, fn in (("move", move), ("select", select), ("denied", denied)):
        wav = os.path.join(WAV_DIR, "menu_%s.wav" % kind)
        write_wav(wav, fn())
        mp3 = os.path.join(MP3_DIR, "menu_%s_v1.mp3" % kind)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-codec:a", "libmp3lame", "-b:a", "96k",
                        "-map_metadata", "-1", "-id3v2_version", "0", "-write_xing", "0", mp3], check=True)
        print("wrote", wav, os.path.getsize(wav), "and", mp3, os.path.getsize(mp3))


if __name__ == "__main__":
    main()
