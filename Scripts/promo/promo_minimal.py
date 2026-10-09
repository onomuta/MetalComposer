#!/usr/bin/env python3
"""
promo_minimal.py — promo_video.py のミニマル版。ネオン/グロー/グリッチを使わず、
明るい背景・余白・タイポグラフィ・柔らかい影だけで構成する。

  * オフホワイト背景にごく淡い「蜃気楼 (Mirage)」のヘイズがゆっくり漂う
  * テキストはマスクの中からせり上がる / 抜ける (エディトリアル系のリビール)
  * アクセントカラーは 1 色だけ (ピリオド・インデックス・進行バー・タッチ表示)
  * モックアップはチタン調の縁 + 大きく柔らかい影。カメラワークは控えめ
  * タイムライン (BPM125・拍スナップ)、モックアップ、タップ検出は promo_video.py と共通

使い方:
    python3 promo_minimal.py input.mov -o promo_minimal.mp4
    python3 promo_minimal.py input.mov --preview 7.5
"""

from __future__ import annotations

import argparse
import math
import os
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from moviepy import AudioArrayClip, AudioFileClip, VideoClip

from promo_video import (
    APP_NAME, BEAT, CAPTION_BEATS, DURATION, FPS, H, T_END, T_MAIN, T_PHONE_IN, W,
    Phone, PhoneStyle, Promo, beat, blit, camera, clamp01, ease_in_out_cubic, ease_out_back,
    ease_out_cubic, ease_out_expo, lerp, load_icon, prog, rounded_rect_mask,
)

# ════════════════════════════════════════════════════════════════════════════
# 設定
# ════════════════════════════════════════════════════════════════════════════

BG = np.array([0.955, 0.951, 0.937], np.float32)        # ウォームなオフホワイト
INK = np.array([0.067, 0.071, 0.082], np.float32)       # ほぼ黒
MUTED = np.array([0.50, 0.50, 0.53], np.float32)
HAIRLINE = np.array([0.80, 0.80, 0.80], np.float32)
ACCENT = np.array([0.18, 0.36, 1.00], np.float32)       # 唯一の差し色 (コバルトブルー)
HAZE_A = np.array([0.80, 0.78, 1.00], np.float32)       # ラベンダー
HAZE_B = np.array([1.00, 0.86, 0.78], np.float32)       # ピーチ

MARGIN = 84

OPENING_LINES = ("Next Gen", "App.")
# (見出し行, 英語サブ) — 見出し末尾の「。」「.」はアクセントカラーになる
CAPTIONS = [
    (("爆速で、", "完結。"), "Blazing fast."),
    (("直感的な", "UI。"), "Intuitive by design."),
    (("GPUで描く、", "無限の表現。"), "Powered by Metal."),
]
CTA_COPY = "繋ぐだけで、映像が動き出す。"
CTA_LABEL = "App Store で検索"
CTA_PLATFORMS = "iPhone  /  Mac"

MIN_PHONE = PhoneStyle(
    rim_top=(0.62, 0.62, 0.64),    # チタン調
    rim_bottom=(0.32, 0.32, 0.35),
    rim_strength=1.0,
    body_tint=(1.0, 1.0, 1.02),
    side_color=(0.10, 0.10, 0.11),
    edge_color=None,
    underglow=None,
    shadow_offset=(26, 64),
    shadow_blur=20,
    shadow_strength=0.30,
    sheen=0.05,
)

# 控えめなカメラ: 下からスライドイン → キャプション毎に少しだけ位置/角度を変える → 下へ退場
MIN_CAM_KEYS = [
    (T_PHONE_IN,          0.10,  0.20,  0.00, 0.90, W * 0.50, H + 760),
    (T_PHONE_IN + 0.70,  -0.10,  0.06,  0.00, 0.90, W * 0.50, H * 0.635),
    (beat(13) - 0.35,    -0.08,  0.05,  0.00, 0.91, W * 0.50, H * 0.635),
    (beat(13) + 0.40,     0.12,  0.06,  0.00, 0.95, W * 0.56, H * 0.640),
    (beat(19) - 0.35,     0.10,  0.05,  0.00, 0.96, W * 0.56, H * 0.640),
    (beat(19) + 0.40,    -0.04,  0.14,  0.00, 0.90, W * 0.48, H * 0.630),
    (T_END,              -0.03,  0.12,  0.00, 0.90, W * 0.48, H * 0.630),
    (T_END + 0.60,        0.00,  0.25,  0.00, 0.86, W * 0.50, H + 820),
]

FONTS = {
    # (パス, ttc index, SF の可変軸 weight または None)
    "display": [("/System/Library/Fonts/SFNS.ttf", 0, 700),
                ("/System/Library/Fonts/Avenir Next.ttc", 0, None),
                ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 0, None)],
    "text": [("/System/Library/Fonts/SFNS.ttf", 0, 510),
             ("/System/Library/Fonts/Avenir Next.ttc", 5, None),
             ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0, None)],
    "jp_display": [("/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc", 0, None),
                   ("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", 0, None),
                   ("C:/Windows/Fonts/YuGothB.ttc", 0, None)],
    "jp_text": [("/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc", 0, None),
                ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 0, None),
                ("C:/Windows/Fonts/YuGothM.ttc", 0, None)],
}

# ════════════════════════════════════════════════════════════════════════════
# タイポグラフィ (マスク・リビール)
# ════════════════════════════════════════════════════════════════════════════


@lru_cache(maxsize=None)
def mfont(key: str, size: int) -> ImageFont.FreeTypeFont:
    for path, index, weight in FONTS[key]:
        if not Path(path).exists():
            continue
        f = ImageFont.truetype(path, size, index=index)
        if weight is not None:
            try:  # SF Pro 可変フォント: Width, Optical Size, GRAD, Weight
                f.set_variation_by_axes([100, max(17, min(size, 96)), 400, weight])
            except OSError:
                pass
        return f
    return ImageFont.load_default(size)


@lru_cache(maxsize=256)
def line_mask(text: str, key: str, size: int, tracking: float = 0.0) -> tuple[np.ndarray, np.ndarray, int]:
    """1 行のアルファマスク。末尾の句点/ピリオドだけ別マスク (アクセント色用) に分ける。
    戻り値: (本文マスク, アクセントマスク, ベースラインまでの高さ)"""
    f = mfont(key, size)
    ascent, descent = f.getmetrics()
    accent_from = len(text) - 1 if text[-1:] in ("。", ".") else len(text)
    width = int(sum(f.getlength(c) for c in text) + tracking * max(len(text) - 1, 0)) + 4
    body = Image.new("L", (width, ascent + descent), 0)
    acc = Image.new("L", body.size, 0)
    db, da = ImageDraw.Draw(body), ImageDraw.Draw(acc)
    x = 0.0
    for i, ch in enumerate(text):
        (da if i >= accent_from else db).text((x, 0), ch, font=f, fill=255)
        x += f.getlength(ch) + tracking
    return (np.asarray(body, np.float32) / 255.0, np.asarray(acc, np.float32) / 255.0, ascent)


def reveal(img: np.ndarray, text: str, key: str, size: int, x: float, y: float, t_local: float, *,
           hold: float = 99.0, color: np.ndarray = INK, accent: np.ndarray | None = ACCENT,
           align: str = "left", tracking: float = 0.0, dur: float = 0.65, out_dur: float = 0.4) -> float:
    """行がマスク (行の高さの窓) の下からせり上がり、hold 秒後に上へ抜ける。y は行の上端。
    行の幅を返す (レイアウト用)。"""
    body, acc, _ = line_mask(text, key, size, tracking)
    h, w = body.shape
    if align == "center":
        x -= w / 2
    elif align == "right":
        x -= w
    if t_local < 0:
        return w
    p_in = ease_out_expo(prog(t_local, 0, dur))
    p_out = ease_in_out_cubic(prog(t_local, hold, out_dur))
    off = int(round((1 - p_in) * h * 1.05 - p_out * h * 1.05))   # +: 下にずれている / -: 上に抜けている
    if abs(off) >= h:
        return w
    rows = slice(0, h - off) if off >= 0 else slice(-off, h)
    ty = int(y) + max(off, 0)
    blit(img, color, body[rows], int(x), ty)
    if accent is not None and acc.any():
        blit(img, accent, acc[rows], int(x), ty)
    elif acc.any():
        blit(img, color, acc[rows], int(x), ty)
    return w


def hairline(img: np.ndarray, x0: float, x1: float, y: float, color: np.ndarray, thick: int = 2,
             opacity: float = 1.0) -> None:
    if x1 - x0 < 1 or opacity <= 0:
        return
    xi0, xi1, yi = int(max(x0, 0)), int(min(x1, W)), int(y)
    img[yi:yi + thick, xi0:xi1] = img[yi:yi + thick, xi0:xi1] * (1 - opacity) + color * opacity


# ════════════════════════════════════════════════════════════════════════════
# 背景 / タッチ表示 / アイコン
# ════════════════════════════════════════════════════════════════════════════

_GY, _GX = np.mgrid[0:H // 6, 0:W // 6].astype(np.float32) * 6


def haze(t: float) -> np.ndarray:
    """2 つの淡い色の塊がゆっくり漂う背景 (1/6 解像度で計算して拡大)。"""
    def blob(cx, cy, r):
        return np.exp(-(((_GX - cx) / r) ** 2 + ((_GY - cy) / (r * 1.25)) ** 2))[..., None]

    a = blob(W * (0.25 + 0.10 * math.sin(t * 0.35)), H * (0.30 + 0.05 * math.cos(t * 0.27)), 520)
    b = blob(W * (0.80 + 0.08 * math.cos(t * 0.31)), H * (0.72 + 0.06 * math.sin(t * 0.23)), 600)
    small = BG + (HAZE_A - BG) * a * 0.55 + (HAZE_B - BG) * b * 0.45
    return cv2.resize(small.astype(np.float32), (W, H), interpolation=cv2.INTER_CUBIC)


def draw_touches(screen: np.ndarray, taps, t: float) -> None:
    """iOS の「タッチを表示」風: 半透明の白い丸 + 細いリングが一度だけ広がる。"""
    sh, sw = screen.shape[:2]
    alpha = None
    for tap in taps:
        age = t - tap.t
        if not (0 <= age < 0.75):
            continue
        if alpha is None:
            alpha = np.zeros((sh, sw), np.float32)
        cx, cy = int(tap.x * sw), int(tap.y * sh)
        press = clamp01(age / 0.08) * (1 - prog(age, 0.25, 0.2))
        if press > 0:
            cv2.circle(alpha, (cx, cy), int(30 + 4 * press), 0.45 * press, -1, cv2.LINE_AA)
        q = prog(age, 0.05, 0.7)
        if 0 < q < 1:
            cv2.circle(alpha, (cx, cy), int(32 + 130 * ease_out_cubic(q)), 0.75 * (1 - q) ** 1.5,
                       3, cv2.LINE_AA)
    if alpha is not None:
        a = alpha[..., None]
        screen *= 1 - a
        screen += a


def soft_shadow(img: np.ndarray, alpha: np.ndarray, x: int, y: int, strength: float,
                blur: float = 22, dy: int = 24) -> None:
    pad = int(blur * 3)
    sh = cv2.GaussianBlur(np.pad(alpha, pad), (0, 0), blur)
    blit(img, INK, sh, x - pad, y - pad + dy, strength)


# ════════════════════════════════════════════════════════════════════════════
# シーン
# ════════════════════════════════════════════════════════════════════════════


class MinimalPromo(Promo):
    def __init__(self, src_path: Path, src_start: float, src_speed: float):
        super().__init__(src_path, src_start, src_speed)
        self.phone = Phone(self.phone.sh, MIN_PHONE)
        self.icon_rgb, self.icon_a = load_icon(260)

    def frame(self, t: float) -> np.ndarray:
        img = haze(t)
        self.chrome(img, t)
        if t < T_MAIN + 0.5:
            self.opening(img, t)
        if T_PHONE_IN <= t < T_END + 0.7:
            self.main(img, t)
        if t >= T_END - 0.05:
            self.ending(img, t)
        # 冒頭は白からフェードイン
        img = img * prog(t, 0, 0.25) + (1 - prog(t, 0, 0.25))
        return (np.clip(img, 0, 1) * 255).astype(np.uint8)

    def chrome(self, img, t):
        """上部のラベルと下部の進行バー (エディトリアルな枠)。"""
        a = ease_out_cubic(prog(t, 0.2, 0.6))
        reveal(img, APP_NAME.upper(), "text", 26, MARGIN, 84, t - 0.2, color=INK, accent=None, tracking=5)
        reveal(img, "2026", "text", 26, W - MARGIN, 84, t - 0.3, color=MUTED, accent=None,
               align="right", tracking=5)
        y = H - 92
        hairline(img, MARGIN, W - MARGIN, y, HAIRLINE, 2, a)
        hairline(img, MARGIN, MARGIN + (W - 2 * MARGIN) * clamp01(t / DURATION), y, INK, 2, a)

    def opening(self, img, t):
        out = T_PHONE_IN - 0.2  # 抜け始め (端末が下から入るのと入れ替わり)
        cy = H * 0.40
        # アイコン: 拍 1 でポップ
        ip = prog(t, beat(1), 0.55)
        fade = 1 - ease_in_out_cubic(prog(t, out + 0.1, 0.4))
        if ip > 0 and fade > 0:
            s = max(ease_out_back(ip, 1.3), 0.01)
            size = max(int(220 * s), 2)
            rgb = cv2.resize(self.icon_rgb, (size, size), interpolation=cv2.INTER_AREA)
            a = cv2.resize(self.icon_a, (size, size), interpolation=cv2.INTER_AREA)
            x, y = int(W / 2 - size / 2), int(cy - size / 2 - 60 * (1 - fade))
            soft_shadow(img, a, x, y, 0.18 * min(ip * 2, 1) * fade)
            blit(img, rgb, a, x, y, min(ip * 3, 1) * fade)
        reveal(img, APP_NAME, "text", 40, W / 2, cy + 150, t - beat(2), hold=out - beat(2),
               color=MUTED, accent=None, align="center", tracking=1)
        for i, line in enumerate(OPENING_LINES):
            reveal(img, line, "display", 176, W / 2, cy + 250 + i * 190, t - beat(3) - i * 0.08,
                   hold=out - beat(3) + i * 0.04, align="center", tracking=-4)

    def main(self, img, t):
        screen = self.src.get_frame(self.src_time(t)).astype(np.float32) / 255.0
        if screen.shape[:2] != (self.phone.sh, self.phone.sw):
            screen = cv2.resize(screen, (self.phone.sw, self.phone.sh), interpolation=cv2.INTER_AREA)
        draw_touches(screen, self.taps, t)
        self.phone.render(img, None, screen, camera(t, MIN_CAM_KEYS, float_amp=4.0), 1.0)

        for i, (lines, sub) in enumerate(CAPTIONS):
            start = T_MAIN + beat(i * CAPTION_BEATS)
            local = t - start
            if not (0 <= local < beat(CAPTION_BEATS) + 0.5):
                continue
            hold = beat(CAPTION_BEATS) - 0.42
            y0 = 190
            # インデックス + 短いアクセントライン
            reveal(img, f"0{i + 1}", "text", 30, MARGIN, y0, local, hold=hold, color=ACCENT,
                   accent=None, tracking=2)
            lw = ease_out_expo(prog(local, 0.1, 0.6)) * (1 - ease_in_out_cubic(prog(local, hold, 0.35)))
            hairline(img, MARGIN + 60, MARGIN + 60 + 90 * lw, y0 + 20, ACCENT, 2, lw)
            reveal(img, f"/ 0{len(CAPTIONS)}", "text", 30, MARGIN + 170, y0, local - 0.05, hold=hold,
                   color=MUTED, accent=None, tracking=2)
            for j, line in enumerate(lines):
                reveal(img, line, "jp_display", 104, MARGIN - 6, y0 + 70 + j * 128,
                       local - 0.06 - j * 0.07, hold=hold + j * 0.04)
            reveal(img, sub, "text", 36, MARGIN, y0 + 70 + len(lines) * 128 + 22, local - 0.22,
                   hold=hold - 0.04, color=MUTED, accent=None)

    def ending(self, img, t):
        lt = t - T_END
        cy = H * 0.33
        ip = prog(lt, 0.30, 0.6)
        if ip > 0:
            s = max(ease_out_back(ip, 1.3), 0.01)
            size = max(int(260 * s), 2)
            rgb = cv2.resize(self.icon_rgb, (size, size), interpolation=cv2.INTER_AREA)
            a = cv2.resize(self.icon_a, (size, size), interpolation=cv2.INTER_AREA)
            x, y = int(W / 2 - size / 2), int(cy - size / 2)
            soft_shadow(img, a, x, y, 0.20 * min(ip * 2, 1), blur=26, dy=30)
            blit(img, rgb, a, x, y, min(ip * 3, 1))
        reveal(img, APP_NAME, "display", 100, W / 2, cy + 200, lt - beat(1.5), align="center", tracking=-2)
        reveal(img, CTA_COPY, "jp_text", 44, W / 2, cy + 340, lt - beat(2.25), color=MUTED,
               align="center")

        # CTA: 「App Store で検索」ラベル + 検索フィールドに名前がタイプされる
        by = int(cy + 560)
        reveal(img, CTA_LABEL, "jp_display", 40, W / 2, by - 110, lt - beat(3), color=INK, align="center")
        bp = ease_out_expo(prog(lt, beat(3.25), 0.55))
        if bp > 0:
            half = int(380 * bp)
            pill = rounded_rect_mask(half * 2, 112, 56)
            soft_shadow(img, pill, W // 2 - half, by - 56, 0.10 * bp, blur=18, dy=14)
            blit(img, np.array([1, 1, 1], np.float32), pill, W // 2 - half, by - 56, bp)
            if bp > 0.85:
                mx = W // 2 - 310
                cv2.circle(img, (mx, by - 5), 19, MUTED.tolist(), 4, cv2.LINE_AA)
                cv2.line(img, (mx + 13, by + 9), (mx + 27, by + 23), MUTED.tolist(), 5, cv2.LINE_AA)
                n = int(len(APP_NAME) * prog(lt, beat(4), 0.6))
                tx = mx + 50
                if n:
                    body, _, _ = line_mask(APP_NAME[:n], "text", 44)
                    blit(img, INK, body, tx, by - body.shape[0] // 2 - 2)
                    tx += body.shape[1]
                if (int(t / (BEAT / 2)) % 2 == 0) or n < len(APP_NAME):
                    img[by - 26:by + 26, tx + 4:tx + 7] = ACCENT
        reveal(img, CTA_PLATFORMS, "text", 30, W / 2, by + 100, lt - beat(4.5), color=MUTED,
               accent=None, align="center", tracking=4)


# ════════════════════════════════════════════════════════════════════════════
# BGM (ミニマル・ハウス風 125BPM)
# ════════════════════════════════════════════════════════════════════════════


def synth_minimal(sr: int = 44100) -> np.ndarray:
    n = int(DURATION * sr)
    out = np.zeros((n, 2), np.float32)
    rng = np.random.default_rng(11)

    def add(sig, at, gain, pan=0.0):
        i = int(at * sr)
        if i >= n:
            return
        m = min(len(sig), n - i)
        out[i:i + m, 0] += sig[:m] * gain * (1 - pan)
        out[i:i + m, 1] += sig[:m] * gain * (1 + pan)

    tk = np.arange(int(0.35 * sr)) / sr
    kick = np.sin(2 * np.pi * (50 * tk + 70 * 0.03 * (1 - np.exp(-tk / 0.03)))) * np.exp(-tk / 0.12)
    tr = np.arange(int(0.03 * sr)) / sr
    rim = (np.sin(2 * np.pi * 1700 * tr) + 0.6 * rng.standard_normal(len(tr))) * np.exp(-tr / 0.006)
    th = np.arange(int(0.05 * sr)) / sr
    hat = np.diff(rng.standard_normal(len(th) + 1)) * np.exp(-th / 0.012)

    def pluck(freqs, length=0.36):
        tp = np.arange(int(length * sr)) / sr
        sig = sum(np.sin(2 * np.pi * f * tp) + 0.25 * np.sin(4 * np.pi * f * tp) for f in freqs)
        return (sig / len(freqs)) * np.exp(-tp / 0.11) * np.minimum(1, tp / 0.004)

    chords = [  # Fmaj9 → Am9 → Dm9 → Bbmaj7 (2 小節毎)
        (174.6, 220.0, 261.6, 329.6, 392.0), (220.0, 261.6, 329.6, 392.0, 493.9),
        (146.8, 174.6, 220.0, 261.6, 329.6), (116.5, 146.8, 174.6, 220.0, 293.7)]
    drop = 6
    for b in range(int(DURATION / BEAT) + 1):
        tb = beat(b)
        if tb > DURATION - 0.5:
            break
        ch = chords[(max(b - drop, 0) // 8) % len(chords)]
        if b >= drop:
            add(kick, tb, 0.75)
            if b % 2 == 1:
                add(rim, tb, 0.18, 0.2)
            add(hat, tb + BEAT / 2, 0.10, -0.3)
        if b % 2 == 0 or b < drop:
            add(pluck(ch), tb + BEAT * 0.75, 0.16, 0.25)
        add(pluck(ch[1:4], 0.25), tb + BEAT * 0.5, 0.07 if b >= drop else 0.05, -0.25)
    # 簡易ディレイで空間を足す
    d = int(BEAT * 0.75 * sr)
    wet = np.zeros_like(out)
    wet[d:] += out[:-d] * 0.28
    wet[2 * d:] += out[:-2 * d] * 0.12
    out += wet[:, ::-1]  # ピンポン
    out *= np.minimum(1, (DURATION - np.arange(n) / sr) / 0.5)[:, None].astype(np.float32)
    return np.tanh(out * 1.3) * 0.75


# ════════════════════════════════════════════════════════════════════════════


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", default="input.mov", type=Path)
    ap.add_argument("-o", "--output", default="promo_minimal.mp4", type=Path)
    ap.add_argument("--src-start", type=float, default=0.0)
    ap.add_argument("--src-speed", type=float, default=2.0)
    ap.add_argument("--music", type=Path)
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--preview", type=float, metavar="SEC")
    args = ap.parse_args()

    promo = MinimalPromo(args.input, args.src_start, args.src_speed)
    try:
        if args.preview is not None:
            out = args.output.with_suffix(f".{args.preview:05.2f}s.png")
            Image.fromarray(promo.frame(args.preview)).save(out)
            print(f"→ {out}")
            return
        clip = VideoClip(promo.frame, duration=DURATION)
        audio = None
        if args.music:
            audio = AudioFileClip(str(args.music))
            audio = audio.subclipped(0, min(DURATION, audio.duration))
        elif not args.no_audio:
            audio = AudioArrayClip(synth_minimal(), fps=44100)
        if audio is not None:
            clip = clip.with_audio(audio)
        clip.write_videofile(
            str(args.output), fps=FPS, codec="libx264", audio_codec="aac", audio_bitrate="192k",
            preset="medium", threads=os.cpu_count(),
            ffmpeg_params=["-crf", "17", "-movflags", "+faststart", "-profile:v", "high"],
        )
        clip.close()
        if audio is not None:
            audio.close()
        print(f"→ {args.output}")
    finally:
        promo.close()


if __name__ == "__main__":
    main()
