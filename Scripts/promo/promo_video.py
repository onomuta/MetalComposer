#!/usr/bin/env python3
"""
promo_video.py — アプリ画面録画 (input.mov) から 15 秒の縦型告知動画を生成する。

  * 1080x1920 / 30fps / 15s / BPM 125 (1 拍 = 0.48s)。セクション境界とアニメは拍にスナップ
  * 2.5D スマホモックアップ (透視変換 + 側面の厚み + 影 + ネオンリム) に録画をはめ込み
  * 録画のフレーム差分からタップ (急な UI 変化) を自動検出し、画面上に光の波紋 + 粒子を発生
  * 背景: 透視グリッド (床/天井)、走査ライン、ビートに反応する波形、浮遊パーティクル
  * BGM: 125BPM のキック/ハット/ベースを NumPy で合成 (--music で差し替え可)

外部 API は使わず、全て NumPy / OpenCV / Pillow で 1 フレームずつ描画し MoviePy で書き出す。
フレーム関数は t だけから決まる純関数 (状態を持たない) なので、シーク・部分レンダリングも安全。

依存:
    pip install "moviepy>=2.0" numpy opencv-python-headless pillow

使い方:
    python3 promo_video.py input.mov -o promo.mp4
    python3 promo_video.py input.mov --src-start 10 --src-speed 2.5 --music bgm.m4a
    python3 promo_video.py input.mov --preview 7.5      # 1 フレームだけ PNG 出力して確認
"""

from __future__ import annotations

import argparse
import math
import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from moviepy import AudioArrayClip, AudioFileClip, VideoClip, VideoFileClip

cv2.setNumThreads(max(1, (os.cpu_count() or 4) // 2))

# ════════════════════════════════════════════════════════════════════════════
# 設定 (コピーや色はここだけ触れば差し替えられる)
# ════════════════════════════════════════════════════════════════════════════

W, H = 1080, 1920
FPS = 30
DURATION = 15.0
BPM = 125
BEAT = 60.0 / BPM  # 0.48s


def beat(n: float) -> float:
    return n * BEAT


# タイムライン (拍単位)。3.36 / 6.24 / 9.12 / 12.00 秒で切り替わる
T_PHONE_IN = beat(6)       # 2.88s  モックアップ登場開始 (オープニング末尾と重ねる)
T_MAIN = beat(7)           # 3.36s  1 つ目のキャプション
CAPTION_BEATS = 6          # キャプション 1 つあたり 6 拍 (2.88s)
T_END = beat(25)           # 12.00s エンディング開始

OPENING_TITLE = "Next Gen App"
OPENING_KICKER = "INTRODUCING"
CAPTIONS = [
    ("爆速で完結", "BLAZING FAST"),
    ("直感的なUI", "INTUITIVE NODE EDITOR"),
    ("GPUで描く、無限の表現", "POWERED BY METAL"),
]
APP_NAME = "Mirage Composer"
CTA_COPY = "繋ぐだけで、映像が動き出す。"
CTA_SEARCH = "App Store で検索"

SCRIPT_DIR = Path(__file__).resolve().parent
ICON_PATH = SCRIPT_DIR.parent.parent / "Assets" / "AppIcon-1024.png"  # 無ければ自動生成ロゴ

# ネオンパレット (RGB, 0..1)
CYAN = np.array([0.05, 0.92, 1.00], np.float32)
MAGENTA = np.array([1.00, 0.16, 0.72], np.float32)
VIOLET = np.array([0.52, 0.32, 1.00], np.float32)
WHITE = np.array([1.0, 1.0, 1.0], np.float32)
BG_TOP = np.array([0.012, 0.016, 0.045], np.float32)
BG_BOTTOM = np.array([0.030, 0.012, 0.070], np.float32)

# モックアップ寸法 (正面から見たときのピクセル)
SCREEN_W = 540
BEZEL = 20
PHONE_RADIUS = 78
PHONE_DEPTH = 34           # 側面の厚み
FOCAL = 2400.0             # 透視の焦点距離 (小さいほどパースが強い)

RIPPLE_LIFE = 0.9          # 波紋 1 つの寿命 (秒)

FONT_CANDIDATES = {
    # macOS → Linux (Noto) → Windows の順で探す
    "jp_heavy": [("/System/Library/Fonts/ヒラギノ角ゴシック W8.ttc", 0),
                 ("/usr/share/fonts/opentype/noto/NotoSansCJK-Black.ttc", 0),
                 ("C:/Windows/Fonts/YuGothB.ttc", 0)],
    "jp_medium": [("/System/Library/Fonts/ヒラギノ角ゴシック W5.ttc", 0),
                  ("/usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc", 0),
                  ("C:/Windows/Fonts/YuGothM.ttc", 0)],
    "latin_heavy": [("/System/Library/Fonts/Avenir Next.ttc", 8),
                    ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 0),
                    ("C:/Windows/Fonts/arialbd.ttf", 0)],
    "latin_demi": [("/System/Library/Fonts/Avenir Next.ttc", 2),
                   ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0),
                   ("C:/Windows/Fonts/arial.ttf", 0)],
    "mono": [("/System/Library/Fonts/Menlo.ttc", 1),
             ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 0),
             ("C:/Windows/Fonts/consolab.ttf", 0)],
}

# ════════════════════════════════════════════════════════════════════════════
# 汎用ヘルパー
# ════════════════════════════════════════════════════════════════════════════


def clamp01(x: float) -> float:
    return 0.0 if x < 0.0 else 1.0 if x > 1.0 else x


def prog(t: float, start: float, dur: float) -> float:
    return clamp01((t - start) / dur)


def ease_out_cubic(p: float) -> float:
    return 1 - (1 - p) ** 3


def ease_out_expo(p: float) -> float:
    return 1.0 if p >= 1 else 1 - 2 ** (-10 * p)


def ease_in_out_cubic(p: float) -> float:
    return 4 * p ** 3 if p < 0.5 else 1 - (-2 * p + 2) ** 3 / 2


def ease_out_back(p: float, s: float = 1.9) -> float:
    p -= 1
    return 1 + (s + 1) * p ** 3 + s * p ** 2


def lerp(a, b, p):
    return a + (b - a) * p


def beat_pulse(t: float, decay: float = 0.11) -> float:
    """拍頭で 1、指数減衰するパルス。"""
    return math.exp(-((t % BEAT) / decay)) if t >= 0 else 0.0


def hash01(*xs: float) -> float:
    """決定的な疑似乱数 (フレーム間で状態を持たないため)。"""
    v = math.sin(sum(x * k for x, k in zip(xs, (12.9898, 78.233, 37.719, 4.581)))) * 43758.5453
    return v - math.floor(v)


def blit(dst: np.ndarray, src_rgb: np.ndarray, alpha: np.ndarray, x: int, y: int,
         opacity: float = 1.0, additive: bool = False) -> None:
    """dst(float32 HxWx3) の (x, y) に src を合成。画面外ははみ出し分だけクリップする。"""
    if opacity <= 0.003:
        return
    h, w = alpha.shape[:2]
    x0, y0 = max(x, 0), max(y, 0)
    x1, y1 = min(x + w, dst.shape[1]), min(y + h, dst.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    sx, sy = x0 - x, y0 - y
    a = alpha[sy:sy + y1 - y0, sx:sx + x1 - x0, None] * opacity
    s = src_rgb if src_rgb.ndim == 1 else src_rgb[sy:sy + y1 - y0, sx:sx + x1 - x0]
    region = dst[y0:y1, x0:x1]
    if additive:
        region += s * a
    else:
        region *= 1 - a
        region += s * a


def rounded_rect_mask(w: int, h: int, r: int, ss: int = 4) -> np.ndarray:
    """アンチエイリアス付き角丸マスク (float32 0..1)。"""
    img = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(img).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], r * ss, fill=255)
    return np.asarray(img.resize((w, h), Image.LANCZOS), np.float32) / 255.0


def add_glow(img: np.ndarray, neon: np.ndarray, strength: float = 1.5) -> None:
    """neon レイヤーを 1/4 解像度でブラーしてブルームとして加算 (フル解像度ブラーより ~16 倍速い)。"""
    small = cv2.resize(neon, (W // 4, H // 4), interpolation=cv2.INTER_AREA)
    g1 = cv2.GaussianBlur(small, (0, 0), 4)
    g2 = cv2.GaussianBlur(small, (0, 0), 14)
    bloom = cv2.resize(g1 * 0.9 + g2 * 1.1, (W, H), interpolation=cv2.INTER_LINEAR)
    img += neon
    img += bloom * strength


# ════════════════════════════════════════════════════════════════════════════
# テキスト
# ════════════════════════════════════════════════════════════════════════════


@lru_cache(maxsize=None)
def font(key: str, size: int) -> ImageFont.FreeTypeFont:
    for path, index in FONT_CANDIDATES[key]:
        if Path(path).exists():
            return ImageFont.truetype(path, size, index=index)
    return ImageFont.load_default(size)


@lru_cache(maxsize=1024)
def glyph(ch: str, key: str, size: int) -> tuple[np.ndarray, int, float]:
    """1 文字のアルファマスク, ベースライン基準の上端オフセット, 送り幅。"""
    f = font(key, size)
    ascent, descent = f.getmetrics()
    pad = size // 4
    img = Image.new("L", (int(f.getlength(ch)) + pad * 2, ascent + descent + pad * 2), 0)
    ImageDraw.Draw(img).text((pad, pad), ch, font=f, fill=255)
    return np.asarray(img, np.float32) / 255.0, pad, f.getlength(ch)


def text_width(text: str, key: str, size: int, tracking: float) -> float:
    return sum(glyph(c, key, size)[2] for c in text) + tracking * max(len(text) - 1, 0)


SCRAMBLE = "!<>-_\\/[]{}=+*^?#ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"


def draw_text(img: np.ndarray, neon: np.ndarray, text: str, key: str, size: int,
              cx: float, cy: float, t_local: float, *, hold: float = 99.0,
              color: np.ndarray = WHITE, glow_color: np.ndarray | None = CYAN,
              tracking: float = 0.0, stagger: float = 0.035, rise: float = 70.0,
              scramble: bool = False, glitch: float = 0.0, opacity: float = 1.0) -> None:
    """1 文字ずつスタッガーで立ち上がり、hold 秒後に上へ抜けるタイポアニメ。

    scramble=True で各文字がランダム記号から確定する「デコード」演出。
    glitch>0 で RGB ずれ (色収差) を付ける。
    """
    if t_local < 0 or opacity <= 0:
        return
    total = text_width(text, key, size, tracking)
    x = cx - total / 2
    f = font(key, size)
    ascent, _ = f.getmetrics()
    frame_no = int(t_local * FPS)
    for i, ch in enumerate(text):
        mask, pad, adv = glyph(ch, key, size)
        p_in = ease_out_expo(prog(t_local, i * stagger, 0.45))
        p_out = prog(t_local, hold + i * stagger * 0.5, 0.28) ** 2
        a = p_in * (1 - p_out) * opacity
        if a > 0.003 and ch != " ":
            dy = (1 - p_in) * rise - p_out * rise * 0.8
            if scramble and t_local < i * stagger + 0.32:
                rnd = SCRAMBLE[int(hash01(i, frame_no) * len(SCRAMBLE))]
                mask, _, _ = glyph(rnd, key, size)
            gx, gy = int(x - pad), int(cy - ascent / 2 - pad + dy)
            if glitch > 0.02:
                off = int(round(glitch * (6 + 10 * hash01(i, frame_no, 3))))
                blit(img, MAGENTA, mask, gx - off, gy, a * 0.85, additive=True)
                blit(img, CYAN, mask, gx + off, gy, a * 0.85, additive=True)
            blit(img, color, mask, gx, gy, a)
            if glow_color is not None:
                blit(neon, glow_color, mask, gx, gy, a * 0.55, additive=True)
        x += adv + tracking


# ════════════════════════════════════════════════════════════════════════════
# 背景 (グリッド / 走査ライン / 波形 / パーティクル)
# ════════════════════════════════════════════════════════════════════════════


def make_background() -> np.ndarray:
    y = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    bg = BG_TOP * (1 - y) + BG_BOTTOM * y
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.sqrt(((xx - W / 2) / W) ** 2 + ((yy - H * 0.45) / H) ** 2)
    vignette = np.clip(1.15 - d * 1.3, 0.25, 1.0)[..., None]
    bg = bg * vignette
    # 中央にうっすら紫のハロー
    halo = np.exp(-(((xx - W / 2) / (W * 0.55)) ** 2 + ((yy - H * 0.48) / (H * 0.35)) ** 2))
    return (bg + VIOLET * 0.05 * halo[..., None]).astype(np.float32)


def draw_grid(neon: np.ndarray, t: float, intensity: float, build: float) -> None:
    """床と天井の透視グリッド。build (0→1) で消失点から線が走り出す。"""
    if intensity <= 0:
        return
    vx, vy = W / 2, H * 0.47
    pulse = 1 + 0.6 * beat_pulse(t)
    speed = 2.2  # 奥→手前へ流れる速さ (ワールド単位/秒)
    for sign, cam_h in ((1, 520.0), (-1, 380.0)):  # 1 = 床, -1 = 天井
        # 縦ライン: 消失点から放射状
        for k in range(-9, 10):
            lp = clamp01(build * 1.6 - abs(k) * 0.06)
            if lp <= 0:
                continue
            ex = vx + k * 260
            ey = vy + sign * H * 0.62
            x2 = int(lerp(vx, ex, ease_out_cubic(lp)))
            y2 = int(lerp(vy, ey, ease_out_cubic(lp)))
            c = (VIOLET * 0.30 * intensity).tolist()
            cv2.line(neon, (int(vx), int(vy)), (x2, y2), c, 1, cv2.LINE_AA)
        # 横ライン: 奥行き z で間隔が詰まる
        if build < 0.35:
            continue
        hb = clamp01((build - 0.35) / 0.65)
        phase = (t * speed) % 1.0
        for i in range(14):
            z = (i + 1 - phase) * 0.9
            if z <= 0.15:
                continue
            yline = vy + sign * cam_h / z
            if not (0 <= yline < H):
                continue
            fade = clamp01(1.4 - z / 9) * hb
            col = CYAN if sign > 0 else MAGENTA
            c = (col * 0.38 * intensity * fade * pulse).tolist()
            cv2.line(neon, (0, int(yline)), (W, int(yline)), c, 2 if z < 2 else 1, cv2.LINE_AA)


def draw_streaks(neon: np.ndarray, t: float, start: float, count: int = 7, dur: float = 0.55) -> None:
    """画面を横切る高速ネオンライン (オープニング・セクション切り替え用)。"""
    for i in range(count):
        t0 = start + i * 0.06
        p = prog(t, t0, dur)
        if p <= 0 or p >= 1:
            continue
        y = int(H * (0.12 + 0.76 * hash01(i, start)))
        direction = 1 if i % 2 == 0 else -1
        head = lerp(-300, W + 300, ease_in_out_cubic(p))
        if direction < 0:
            head = W - head
        tail = head - direction * 420 * math.sin(p * math.pi)
        col = (CYAN if i % 3 else MAGENTA) * 1.4
        cv2.line(neon, (int(tail), y), (int(head), y), col.tolist(), 3, cv2.LINE_AA)


def draw_waveforms(neon: np.ndarray, t: float, intensity: float) -> None:
    if intensity <= 0:
        return
    xs = np.linspace(0, W, 120, dtype=np.float32)
    amp_beat = 1 + 1.3 * beat_pulse(t, 0.16)
    for j, (base_y, col, freq, spd) in enumerate((
            (H * 0.905, CYAN, 3.0, 1.6),
            (H * 0.925, MAGENTA, 4.5, -2.1),
            (H * 0.090, VIOLET, 2.2, 1.1))):
        env = np.sin(np.pi * xs / W) ** 1.5
        y = base_y + env * 26 * amp_beat * (
            np.sin(xs / W * freq * 2 * np.pi + t * spd * 2 * np.pi) * 0.7
            + np.sin(xs / W * freq * 5.1 * np.pi - t * spd * 3.3) * 0.3)
        pts = np.stack([xs, y], axis=1).astype(np.int32)[None]
        cv2.polylines(neon, pts, False, (col * 0.75 * intensity).tolist(), 2, cv2.LINE_AA)


@dataclass(frozen=True)
class Dust:
    x: np.ndarray
    y: np.ndarray
    speed: np.ndarray
    size: np.ndarray
    phase: np.ndarray
    hue: np.ndarray


def make_dust(n: int = 140, seed: int = 7) -> Dust:
    rng = np.random.default_rng(seed)
    return Dust(rng.uniform(0, W, n), rng.uniform(0, H, n), rng.uniform(30, 140, n),
                rng.uniform(1.2, 3.2, n), rng.uniform(0, 2 * np.pi, n), rng.integers(0, 3, n))


def draw_dust(neon: np.ndarray, dust: Dust, t: float, intensity: float) -> None:
    if intensity <= 0:
        return
    ys = (dust.y - dust.speed * t) % H
    xs = (dust.x + 18 * np.sin(t * 0.8 + dust.phase)) % W
    tw = 0.45 + 0.55 * np.sin(t * 3 + dust.phase * 3) ** 2
    cols = (CYAN, MAGENTA, VIOLET)
    for x, y, s, a, h in zip(xs, ys, dust.size, tw, dust.hue):
        cv2.circle(neon, (int(x), int(y)), int(s), (cols[h] * a * 0.8 * intensity).tolist(), -1, cv2.LINE_AA)


# ════════════════════════════════════════════════════════════════════════════
# タップ検出と波紋
# ════════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class Tap:
    t: float    # 出力動画上の時刻
    x: float    # スクリーン座標 (0..1)
    y: float


def detect_taps(clip: VideoFileClip, src_time, t0: float, t1: float,
                rate: float = 20.0, min_gap: float = 0.42) -> list[Tap]:
    """フレーム差分から「急な UI 変化 (=タップ直後)」を検出する。

    常にアニメーションしている領域 (プレビュー等) に引っ張られないよう、
    セル毎に差分の時間中央値をベースラインとして引き、その超過分だけを見る。
    """
    gw, gh = 12, 26
    times = np.arange(t0, t1, 1.0 / rate)
    prev, cells = None, []
    for t in times:
        g = cv2.cvtColor(clip.get_frame(src_time(t)), cv2.COLOR_RGB2GRAY)
        g = cv2.resize(g, (gw * 8, gh * 8), interpolation=cv2.INTER_AREA).astype(np.float32)
        if prev is not None:
            d = np.abs(g - prev).reshape(gh, 8, gw, 8).mean(axis=(1, 3))
            cells.append(d)
        prev = g
    if len(cells) < 3:
        return []
    cells = np.stack(cells)                                   # (N, gh, gw)
    excess = np.clip(cells - np.median(cells, axis=0) - 4.0, 0, None)
    score = excess.sum(axis=(1, 2))
    thr = max(float(np.median(score)) * 3.0, 60.0)
    taps: list[Tap] = []
    order = np.argsort(-score)
    for i in order:
        if score[i] < thr or len(taps) >= 10:
            break
        t = float(times[i + 1])
        if any(abs(t - p.t) < min_gap for p in taps):
            continue
        w = excess[i]
        yy, xx = np.mgrid[0:gh, 0:gw]
        tot = w.sum()
        taps.append(Tap(t - 0.05, float((xx * w).sum() / tot + 0.5) / gw,
                        float((yy * w).sum() / tot + 0.5) / gh))
    return sorted(taps, key=lambda p: p.t)


def fallback_taps(t0: float, t1: float) -> list[Tap]:
    """検出できなかった場合は 2 拍毎にそれらしい位置で波紋を出す。"""
    n0, n1 = math.ceil(t0 / BEAT), math.floor(t1 / BEAT)
    return [Tap(beat(n), 0.25 + 0.5 * hash01(n, 1), 0.3 + 0.5 * hash01(n, 2))
            for n in range(n0, n1, 2)]


def draw_ripples(screen: np.ndarray, taps: list[Tap], t: float) -> None:
    """スクリーン画像 (float32) に波紋 + 放射パーティクルを加算描画。モックアップと一緒に変形される。"""
    sh, sw = screen.shape[:2]
    fx = None
    for k, tap in enumerate(taps):
        age = t - tap.t
        if not (0 <= age < RIPPLE_LIFE):
            continue
        if fx is None:
            fx = np.zeros_like(screen)
        p = age / RIPPLE_LIFE
        cx, cy = int(tap.x * sw), int(tap.y * sh)
        for delay, col in ((0.0, CYAN), (0.12, MAGENTA)):
            q = clamp01((age - delay) / (RIPPLE_LIFE - delay))
            if 0 < q < 1:
                r = int(18 + 240 * ease_out_cubic(q))
                cv2.circle(fx, (cx, cy), r, (col * (1 - q) ** 1.4 * 1.6).tolist(),
                           max(1, int(7 * (1 - q))), cv2.LINE_AA)
        if p < 0.35:
            cv2.circle(fx, (cx, cy), int(34 * (1 - p / 0.35)), (WHITE * 1.2).tolist(), -1, cv2.LINE_AA)
        for j in range(18):
            ang = 2 * math.pi * (j / 18 + hash01(k, j) * 0.05)
            dist = (30 + 250 * (0.5 + hash01(k, j, 1))) * ease_out_expo(p)
            px, py = cx + math.cos(ang) * dist, cy + math.sin(ang) * dist
            col = CYAN if j % 2 else MAGENTA
            cv2.circle(fx, (int(px), int(py)), max(1, int(5 * (1 - p))),
                       (col * (1 - p) * 1.8).tolist(), -1, cv2.LINE_AA)
    if fx is not None:
        screen += fx + cv2.GaussianBlur(fx, (0, 0), 9) * 1.4


# ════════════════════════════════════════════════════════════════════════════
# 2.5D モックアップ
# ════════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class PhoneStyle:
    """モックアップの見た目。ネオン版とミニマル版で差し替える。"""
    rim_top: tuple = tuple(CYAN)          # 縁取りの色 (上→下へグラデーション)
    rim_bottom: tuple = tuple(MAGENTA)
    rim_strength: float = 0.9
    body_tint: tuple = (0.9, 0.95, 1.1)
    side_color: tuple = (0.06, 0.06, 0.09)
    edge_color: tuple | None = tuple(MAGENTA * 0.5)  # 側面輪郭の発光 (neon レイヤーへ)。None で無し
    underglow: tuple | None = tuple(VIOLET * 0.55 + CYAN * 0.15)
    shadow_offset: tuple = (40, 70)
    shadow_blur: float = 12               # 1/4 解像度でのシグマ
    shadow_strength: float = 0.75
    sheen: float = 0.10


class Phone:
    """正面向きの端末レイヤーを用意し、毎フレーム透視変換して合成する。"""

    def __init__(self, screen_h: int, style: PhoneStyle = PhoneStyle()):
        self.style = style
        self.sw, self.sh = SCREEN_W, screen_h
        self.pw, self.ph = SCREEN_W + BEZEL * 2, screen_h + BEZEL * 2
        body_mask = rounded_rect_mask(self.pw, self.ph, PHONE_RADIUS)
        self.screen_mask = rounded_rect_mask(self.sw, self.sh, PHONE_RADIUS - BEZEL)[..., None]
        # 本体: 縦方向にわずかなグラデーションのダークメタル + リム
        g = np.linspace(0.11, 0.05, self.ph, dtype=np.float32)[:, None, None]
        body = np.repeat(np.repeat(g, self.pw, axis=1), 3, axis=2) * np.array(style.body_tint, np.float32)
        inner = rounded_rect_mask(self.pw - 6, self.ph - 6, PHONE_RADIUS - 3)
        rim = body_mask.copy()
        rim[3:-3, 3:-3] -= inner
        rim_col = np.linspace(0, 1, self.ph, dtype=np.float32)[:, None, None]
        body += (np.clip(rim, 0, 1)[..., None] * style.rim_strength
                 * (np.float32(style.rim_top) * (1 - rim_col) + np.float32(style.rim_bottom) * rim_col))
        self.body = body.astype(np.float32)
        self.alpha = body_mask
        # ダイナミックアイランド
        self.island = rounded_rect_mask(150, 42, 21)[..., None]
        self.src_quad = np.float32([[0, 0], [self.pw, 0], [self.pw, self.ph], [0, self.ph]])
        # 角丸の輪郭 (側面の凸包用。四隅の点だけだと角から側面がはみ出す)
        r = PHONE_RADIUS
        arcs = []
        for (ox, oy), a0 in (((self.pw - r, r), -90), ((self.pw - r, self.ph - r), 0),
                             ((r, self.ph - r), 90), ((r, r), 180)):
            a = np.radians(np.linspace(a0, a0 + 90, 10))
            arcs.append(np.stack([ox + r * np.cos(a), oy + r * np.sin(a)], axis=1))
        self.outline = np.concatenate(arcs).astype(np.float32)

    def compose_flat(self, screen: np.ndarray) -> np.ndarray:
        """スクリーン映像を本体にはめ込んだ RGBA (float32)。"""
        rgba = np.empty((self.ph, self.pw, 4), np.float32)
        rgba[..., :3] = self.body
        rgba[..., 3] = self.alpha
        region = rgba[BEZEL:BEZEL + self.sh, BEZEL:BEZEL + self.sw, :3]
        region *= 1 - self.screen_mask
        region += np.clip(screen, 0, 4) * self.screen_mask
        ix = (self.pw - 150) // 2
        isl = rgba[BEZEL + 18:BEZEL + 60, ix:ix + 150, :3]
        isl *= 1 - self.island
        return rgba

    def project(self, pts: np.ndarray, z: float, yaw: float, pitch: float, roll: float,
                scale: float, cx: float, cy: float) -> np.ndarray:
        """端末ローカル座標 (中心原点) を 3D 回転 → 透視投影。"""
        x = (pts[:, 0] - self.pw / 2) * scale
        y = (pts[:, 1] - self.ph / 2) * scale
        zz = np.full_like(x, z * scale)
        cr, sr = math.cos(roll), math.sin(roll)
        x, y = x * cr - y * sr, x * sr + y * cr
        cyw, syw = math.cos(yaw), math.sin(yaw)
        x, zz = x * cyw + zz * syw, -x * syw + zz * cyw
        cp, sp = math.cos(pitch), math.sin(pitch)
        y, zz = y * cp - zz * sp, y * sp + zz * cp
        d = FOCAL / (FOCAL + zz)
        return np.stack([cx + x * d, cy + y * d], axis=1).astype(np.float32)

    def render(self, img: np.ndarray, neon: np.ndarray | None, screen: np.ndarray, cam: dict,
               opacity: float) -> None:
        if opacity <= 0.003 or cam["scale"] <= 0.01:
            return
        st = self.style
        args = (cam["yaw"], cam["pitch"], cam["roll"], cam["scale"], cam["cx"], cam["cy"])
        front = self.project(self.src_quad, 0, *args)
        back = self.project(self.src_quad, PHONE_DEPTH, *args)

        # 影 (1/4 解像度で塗ってブラー → 乗算)
        sm = np.zeros((H // 4, W // 4), np.float32)
        cv2.fillConvexPoly(sm, ((back + st.shadow_offset) / 4).astype(np.int32), 1.0, cv2.LINE_AA)
        sm = cv2.resize(cv2.GaussianBlur(sm, (0, 0), st.shadow_blur), (W, H))
        img *= (1 - sm * st.shadow_strength * opacity)[..., None]
        if st.underglow is not None:
            # 背面のアンダーグロー (端末の下に敷くので img に直接加算。neon に入れると画面に被る)
            gm = np.zeros((H // 4, W // 4), np.float32)
            cv2.fillConvexPoly(gm, (back / 4).astype(np.int32), 1.0, cv2.LINE_AA)
            gm = cv2.resize(cv2.GaussianBlur(gm, (0, 0), 22), (W, H))
            img += gm[..., None] * np.float32(st.underglow) * opacity

        # 側面 (前面と背面の凸包を暗いメタルで塗る → 厚みが出る)。外接矩形の中だけで処理
        hull = cv2.convexHull(np.concatenate([self.project(self.outline, 0, *args),
                                              self.project(self.outline, PHONE_DEPTH, *args)]).astype(np.int32))
        x0, y0, w, h = cv2.boundingRect(hull)
        x1, y1 = min(x0 + w, W), min(y0 + h, H)
        x0, y0 = max(x0, 0), max(y0, 0)
        if x1 <= x0 or y1 <= y0:
            return
        side_a = np.zeros((y1 - y0, x1 - x0), np.float32)
        cv2.fillConvexPoly(side_a, hull - [x0, y0], 1.0, cv2.LINE_AA)
        blit(img, np.array(st.side_color, np.float32), side_a, x0, y0, opacity)
        if st.edge_color is not None and neon is not None:
            cv2.polylines(neon, [hull], True, [float(c) * opacity for c in st.edge_color], 2, cv2.LINE_AA)

        # 前面: 必要な矩形だけ warpPerspective (全画面 warp より速い)
        fx0, fy0, fw, fh = cv2.boundingRect(front.astype(np.int32))
        fx0, fy0 = max(fx0 - 2, 0), max(fy0 - 2, 0)
        fx1, fy1 = min(fx0 + fw + 4, W), min(fy0 + fh + 4, H)
        if fx1 <= fx0 or fy1 <= fy0:
            return
        m = cv2.getPerspectiveTransform(self.src_quad, (front - [fx0, fy0]).astype(np.float32))
        flat = self.compose_flat(screen)
        warped = cv2.warpPerspective(flat, m, (fx1 - fx0, fy1 - fy0), flags=cv2.INTER_LINEAR,
                                     borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        rgb, a = warped[..., :3], warped[..., 3]
        # ガラスのハイライト (傾きに応じて流れる斜めのシーン)
        hh, ww = a.shape
        gx = np.linspace(0, 1, ww, dtype=np.float32)[None, :]
        gy = np.linspace(0, 1, hh, dtype=np.float32)[:, None]
        sheen_pos = 0.5 + cam["yaw"] * 1.6
        sheen = np.exp(-((gx + gy * 0.6 - sheen_pos) / 0.09) ** 2) * st.sheen
        rgb = rgb + sheen[..., None]
        blit(img, rgb, a, fx0, fy0, opacity)


# カメラキーフレーム: (時刻, yaw, pitch, roll, scale, cx, cy)。間は ease-in-out 補間
CAM_KEYS = [
    (T_PHONE_IN,          0.55,  0.45, -0.20, 0.35, W * 0.50, H * 1.10),
    (T_PHONE_IN + 0.62,  -0.30,  0.16, -0.05, 1.00, W * 0.50, H * 0.60),
    (beat(13) - 0.30,    -0.20,  0.10, -0.03, 1.04, W * 0.50, H * 0.60),
    (beat(13) + 0.32,     0.28,  0.12,  0.04, 1.18, W * 0.44, H * 0.62),   # 2 つ目: 寄り + 右振り
    (beat(19) - 0.30,     0.20,  0.08,  0.03, 1.22, W * 0.45, H * 0.62),
    (beat(19) + 0.32,    -0.10,  0.32, -0.02, 0.98, W * 0.56, H * 0.60),   # 3 つ目: 見下ろし
    (T_END - 0.05,       -0.04,  0.24,  0.00, 1.04, W * 0.54, H * 0.60),
    (T_END + 0.55,        0.00,  0.70,  0.00, 0.45, W * 0.50, H * 0.40),   # 奥へ倒れて退場
]


def camera(t: float, keys=CAM_KEYS, float_amp: float = 8.0) -> dict:
    if t <= keys[0][0]:
        k = keys[0]
    elif t >= keys[-1][0]:
        k = keys[-1]
    else:
        for a, b in zip(keys, keys[1:]):
            if a[0] <= t <= b[0]:
                p = ease_in_out_cubic((t - a[0]) / (b[0] - a[0]))
                k = tuple(lerp(x, y, p) for x, y in zip(a, b))
                break
    # 常に少しだけ浮遊させる
    float_y = math.sin(t * 1.3) * float_amp
    return dict(yaw=k[1] + math.sin(t * 0.9) * 0.0025 * float_amp, pitch=k[2], roll=k[3], scale=k[4],
                cx=k[5], cy=k[6] + float_y)


# ════════════════════════════════════════════════════════════════════════════
# ロゴ / アイコン
# ════════════════════════════════════════════════════════════════════════════


def hexagon(cx: float, cy: float, r: float, rot: float = -math.pi / 2) -> np.ndarray:
    return np.array([[cx + r * math.cos(rot + i * math.pi / 3), cy + r * math.sin(rot + i * math.pi / 3)]
                     for i in range(6)], np.float32)


def draw_partial_polyline(dst: np.ndarray, pts: np.ndarray, p: float, color, thick: int) -> None:
    """閉じた折れ線を周長の割合 p だけ描く (ストロークが走る演出)。"""
    segs = list(zip(pts, np.roll(pts, -1, axis=0)))
    lens = [float(np.linalg.norm(b - a)) for a, b in segs]
    remain = p * sum(lens)
    for (a, b), L in zip(segs, lens):
        if remain <= 0:
            break
        q = min(1.0, remain / L)
        e = a + (b - a) * q
        cv2.line(dst, tuple(map(int, a)), tuple(map(int, e)), color, thick, cv2.LINE_AA)
        remain -= L


def draw_logo_placeholder(img: np.ndarray, neon: np.ndarray, t: float, cx: float, cy: float,
                          opacity: float) -> None:
    """六角形 + ノードグラフの幾何学ロゴ。線が走って描かれ、拍で脈打つ。"""
    if opacity <= 0:
        return
    pulse = beat_pulse(t) if t > beat(2) else 0
    r = 150 * (1 + 0.04 * pulse)
    p = ease_in_out_cubic(prog(t, 0.25, 0.9))
    draw_partial_polyline(neon, hexagon(cx, cy, r), p, (CYAN * 1.3 * opacity).tolist(), 4)
    draw_partial_polyline(neon, hexagon(cx, cy, r * 0.78, -math.pi / 2 + math.pi / 6),
                          ease_in_out_cubic(prog(t, 0.45, 0.9)), (MAGENTA * 0.9 * opacity).tolist(), 2)
    # 3 つのノードと接続線 (拍ごとに 1 つずつ点灯)
    nodes = [(cx - 62, cy - 40), (cx + 66, cy - 6), (cx - 30, cy + 62)]
    for i, (nx, ny) in enumerate(nodes):
        on = prog(t, beat(2 + i), 0.18) * opacity
        if on <= 0:
            continue
        if i > 0:
            ax, ay = nodes[i - 1]
            ex, ey = lerp(ax, nx, ease_out_cubic(on)), lerp(ay, ny, ease_out_cubic(on))
            cv2.line(neon, (int(ax), int(ay)), (int(ex), int(ey)), (WHITE * 0.9 * on).tolist(), 3, cv2.LINE_AA)
        rad = int(16 * ease_out_back(on) + 5 * pulse)
        cv2.circle(img, (int(nx), int(ny)), rad, (WHITE * on).tolist(), -1, cv2.LINE_AA)
        cv2.circle(neon, (int(nx), int(ny)), rad + 6, ((CYAN if i != 1 else MAGENTA) * on).tolist(), 3, cv2.LINE_AA)


def load_icon(size: int) -> tuple[np.ndarray, np.ndarray]:
    """アプリアイコン (RGB, alpha)。iOS 風の角丸でマスクする。無ければ生成。"""
    mask = rounded_rect_mask(size, size, int(size * 0.2237))
    if ICON_PATH.exists():
        with Image.open(ICON_PATH) as im:
            rgb = np.asarray(im.convert("RGB").resize((size, size), Image.LANCZOS), np.float32) / 255
        return rgb, mask
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    p = ((xx + yy) / 2)[..., None]
    rgb = (VIOLET * 0.4 * (1 - p) + MAGENTA * 0.5 * p).astype(np.float32)
    cv2.polylines(rgb, [hexagon(size / 2, size / 2, size * 0.3).astype(np.int32)], True,
                  CYAN.tolist(), max(2, size // 40), cv2.LINE_AA)
    return rgb, mask


# ════════════════════════════════════════════════════════════════════════════
# シーン
# ════════════════════════════════════════════════════════════════════════════


class Promo:
    def __init__(self, src_path: Path, src_start: float, src_speed: float):
        probe = VideoFileClip(str(src_path), audio=False)
        src_w, src_h = probe.size
        self.src_dur = probe.duration
        probe.close()
        screen_h = int(round(SCREEN_W * src_h / src_w / 2) * 2)
        # ffmpeg 側でスクリーンサイズに縮小して読む (フル解像度デコードより大幅に速い)
        self.src = VideoFileClip(str(src_path), audio=False, target_resolution=(SCREEN_W, screen_h))
        self.src_start, self.src_speed = src_start, src_speed
        self.phone = Phone(screen_h)
        self.bg = make_background()
        self.dust = make_dust()
        self.icon_rgb, self.icon_a = load_icon(300)

        t0, t1 = T_PHONE_IN + 0.5, T_END
        print("タップ (急な画面変化) を解析中…")
        self.taps = detect_taps(self.src, self.src_time, t0, t1) or fallback_taps(t0, t1)
        print(f"  波紋 {len(self.taps)} 個: " + ", ".join(f"{p.t:.2f}s" for p in self.taps))

    def close(self) -> None:
        self.src.close()

    def src_time(self, t: float) -> float:
        st = self.src_start + max(0.0, t - T_PHONE_IN) * self.src_speed
        return min(st, self.src_dur - 0.1)

    # ── フレーム ────────────────────────────────────────────────────────────

    def frame(self, t: float) -> np.ndarray:
        img = self.bg.copy()
        # 背景ネオン (グリッド等) は先に発光まで合成し、モックアップやテキストがその上に乗るようにする
        bg_neon = np.zeros_like(img)
        grid_build = ease_out_cubic(prog(t, 0.0, 1.4))
        grid_int = 1.0 if t < T_MAIN else 0.55
        draw_grid(bg_neon, t, grid_int, grid_build)
        draw_dust(bg_neon, self.dust, t, clamp01(t / 1.0))
        draw_waveforms(bg_neon, t, prog(t, T_PHONE_IN, 0.6))
        draw_streaks(bg_neon, t, 0.05)
        draw_streaks(bg_neon, t, T_PHONE_IN - 0.15, count=5, dur=0.45)
        draw_streaks(bg_neon, t, T_END - 0.12, count=6, dur=0.5)
        add_glow(img, bg_neon)
        del bg_neon

        neon = np.zeros_like(img)  # 前景ネオン (テキストの発光・リム等)
        if t < T_MAIN + 0.4:
            self.opening(img, neon, t)
        if T_PHONE_IN <= t < T_END + 0.7:
            self.main(img, neon, t)
        if t >= T_END - 0.05:
            self.ending(img, neon, t)

        add_glow(img, neon)
        # セクション切り替えのフラッシュ
        for tf in (T_PHONE_IN, beat(13), beat(19), T_END):
            if 0 <= t - tf < 0.25:
                img += (1 - (t - tf) / 0.25) ** 2 * (0.35 if tf in (T_PHONE_IN, T_END) else 0.12)
        # 最後の 0.3s はフェードアウト
        img *= 1 - prog(t, DURATION - 0.3, 0.3)
        return (np.clip(img, 0, 1) * 255).astype(np.uint8)

    def opening(self, img, neon, t):
        out = ease_in_out_cubic(prog(t, T_PHONE_IN - 0.1, 0.45))   # 上へ抜けて消える
        lift = -out * 260
        op = 1 - out
        draw_logo_placeholder(img, neon, t, W / 2, H * 0.40 + lift, op)
        draw_text(img, neon, OPENING_KICKER, "mono", 34, W / 2, H * 0.40 + 230 + lift,
                  t - beat(2), tracking=14, scramble=True, glow_color=MAGENTA, opacity=op * 0.9)
        # ネオン管が点灯するようなフリッカー (決定的ノイズ)
        tt = t - beat(3)
        if tt >= 0:
            fl = 1.0
            if tt < 0.55:
                fl = 1.0 if hash01(int(t * FPS), 9) > 0.45 else 0.15
            fl *= 0.92 + 0.08 * beat_pulse(t)
            draw_text(img, neon, OPENING_TITLE, "latin_heavy", 132, W / 2, H * 0.40 + 330 + lift,
                      tt, stagger=0.03, rise=40, glow_color=CYAN, tracking=2,
                      glitch=beat_pulse(t, 0.07) * 1.2, opacity=fl * op)

    def main(self, img, neon, t):
        cam = camera(t)
        screen = self.src.get_frame(self.src_time(t)).astype(np.float32) / 255.0
        if screen.shape[:2] != (self.phone.sh, self.phone.sw):
            screen = cv2.resize(screen, (self.phone.sw, self.phone.sh), interpolation=cv2.INTER_AREA)
        draw_ripples(screen, self.taps, t)
        opacity = 1 - ease_in_out_cubic(prog(t, T_END + 0.05, 0.5))
        self.phone.render(img, neon, screen, cam, opacity)

        # キャプション (6 拍ごとに切り替え、拍頭でグリッチ)
        for i, (jp, en) in enumerate(CAPTIONS):
            start = T_MAIN + beat(i * CAPTION_BEATS)
            local = t - start
            if not (0 <= local < beat(CAPTION_BEATS) + 0.1):
                continue
            hold = beat(CAPTION_BEATS) - 0.36
            size = min(118, int(118 * (W - 120) / text_width(jp, "jp_heavy", 118, 4)))
            draw_text(img, neon, jp, "jp_heavy", size, W / 2, 255, local, hold=hold,
                      glow_color=CYAN if i != 1 else MAGENTA, tracking=4,
                      glitch=beat_pulse(t, 0.06) * 0.9)
            draw_text(img, neon, en, "mono", 32, W / 2, 380, local - 0.18, hold=hold - 0.1,
                      color=CYAN if i != 1 else MAGENTA, glow_color=None, tracking=10,
                      stagger=0.018, rise=20, scramble=True)
            # 見出し下のライン: 拍に合わせて伸縮
            lw = ease_out_expo(prog(local, 0.1, 0.5)) * (1 - prog(local, hold, 0.25))
            half = int(220 * lw * (1 + 0.15 * beat_pulse(t)))
            if half > 0:
                cv2.line(neon, (W // 2 - half, 330), (W // 2 + half, 330), (CYAN * 1.2).tolist(), 3, cv2.LINE_AA)

        # 画面上部の HUD 風インジケーター (3 セグメントで進行度)
        if t >= T_MAIN:
            for i in range(3):
                seg_p = prog(t, T_MAIN + beat(i * CAPTION_BEATS), beat(CAPTION_BEATS))
                x0 = W // 2 - 150 + i * 105
                fade = 1 - prog(t, T_END, 0.3)
                cv2.line(img, (x0, 120), (x0 + 90, 120), (WHITE * 0.25 * fade).tolist(), 4, cv2.LINE_AA)
                if seg_p > 0:
                    cv2.line(neon, (x0, 120), (x0 + int(90 * seg_p), 120), (CYAN * fade).tolist(), 4, cv2.LINE_AA)

    def ending(self, img, neon, t):
        lt = t - T_END
        cy = H * 0.36
        # アイコン: オーバーシュートで出現 + 周囲を回るネオンリング
        ip = prog(lt, 0.22, 0.55)
        if ip > 0:
            s = max(ease_out_back(ip), 0.01) * (1 + 0.03 * beat_pulse(t))
            size = max(int(300 * s), 2)
            rgb = cv2.resize(self.icon_rgb, (size, size), interpolation=cv2.INTER_LINEAR)
            a = cv2.resize(self.icon_a, (size, size), interpolation=cv2.INTER_LINEAR)
            # 背後の発光は img に直接 (neon に入れるとアイコン自体が白飛びする)
            halo = cv2.GaussianBlur(np.pad(a, 70), (0, 0), 26)
            blit(img, VIOLET * 0.8 + MAGENTA * 0.3, halo, int(W / 2 - size / 2) - 70,
                 int(cy - size / 2) - 70, 0.9 * min(ip * 2, 1), additive=True)
            blit(img, rgb, a, int(W / 2 - size / 2), int(cy - size / 2), min(ip * 3, 1))
            rot = lt * 140
            for k, col in enumerate((CYAN, MAGENTA)):
                sweep = 300 * ease_out_expo(ip)
                cv2.ellipse(neon, (W // 2, int(cy)), (215 + k * 22, 215 + k * 22), 0,
                            rot * (1 if k == 0 else -1.3) + k * 90,
                            rot * (1 if k == 0 else -1.3) + k * 90 + sweep * (0.8 - k * 0.3),
                            (col * 1.1).tolist(), 3, cv2.LINE_AA)
        draw_text(img, neon, APP_NAME, "latin_heavy", 92, W / 2, cy + 330, lt - beat(1.5),
                  tracking=3, glow_color=CYAN, glitch=beat_pulse(t, 0.06) * 0.6)
        draw_text(img, neon, CTA_COPY, "jp_medium", 50, W / 2, cy + 440, lt - beat(2.25),
                  stagger=0.025, rise=30, glow_color=MAGENTA)

        # 検索バー: 枠が左右に伸び → 虫眼鏡 → テキストがタイプされる
        by = int(cy + 640)
        bp = ease_out_expo(prog(lt, beat(3), 0.45))
        if bp > 0:
            half_w = int(410 * bp)
            box = np.zeros((124, half_w * 2 + 2), np.float32)
            cv2.rectangle(box, (0, 0), (box.shape[1] - 1, 123), 1.0, -1)
            rr = rounded_rect_mask(box.shape[1], 124, 62)
            blit(img, np.array([0.08, 0.08, 0.14], np.float32), rr, W // 2 - half_w, by - 62, 0.85 * bp)
            outline = rr - np.pad(rounded_rect_mask(box.shape[1] - 6, 118, 59), 3)
            blit(neon, CYAN, np.clip(outline, 0, 1), W // 2 - half_w, by - 62, 1.2 * bp, additive=True)
            if bp > 0.9:
                mx = W // 2 - 340
                cv2.circle(img, (mx, by - 6), 22, WHITE.tolist(), 5, cv2.LINE_AA)
                cv2.line(img, (mx + 16, by + 10), (mx + 32, by + 26), WHITE.tolist(), 6, cv2.LINE_AA)
                n = int(len(CTA_SEARCH) * prog(lt, beat(3.75), 0.7))
                typed = CTA_SEARCH[:n]
                tx = W // 2 - 290
                tsize = 46 if len(CTA_SEARCH) <= 16 else 40
                wtyped = text_width(typed, "jp_medium", tsize, 0)
                draw_text(img, neon, typed, "jp_medium", tsize, tx + wtyped / 2, by, 1.0,
                          stagger=0, rise=0, glow_color=None)
                if (int(t / (BEAT / 2)) % 2 == 0) or n < len(CTA_SEARCH):
                    cx = int(tx + wtyped + 8)
                    cv2.line(neon, (cx, by - 26), (cx, by + 26), (CYAN * 1.5).tolist(), 4)

        # 光のスイープ (最後の決め)
        sp = prog(lt, beat(4.75), 0.6)
        if 0 < sp < 1:
            xs = np.arange(W, dtype=np.float32)[None, :]
            ys = np.arange(H, dtype=np.float32)[:, None]
            band = np.exp(-((xs + ys * 0.35 - lerp(-600, W + 900, sp)) / 60) ** 2) * 0.12
            img += band[..., None] * WHITE


# ════════════════════════════════════════════════════════════════════════════
# BGM 合成 (125BPM)
# ════════════════════════════════════════════════════════════════════════════


def synth_bgm(sr: int = 44100) -> np.ndarray:
    n = int(DURATION * sr)
    out = np.zeros(n, np.float32)
    rng = np.random.default_rng(3)

    def add(sig: np.ndarray, at: float, gain: float) -> None:
        i = int(at * sr)
        if i >= n:
            return
        m = min(len(sig), n - i)
        out[i:i + m] += sig[:m] * gain

    tk = np.arange(int(0.45 * sr)) / sr
    kick = np.sin(2 * np.pi * (45 * tk + (150 - 45) * 0.035 * (1 - np.exp(-tk / 0.035)))) * np.exp(-tk / 0.16)
    th = np.arange(int(0.08 * sr)) / sr
    hat = np.diff(rng.standard_normal(len(th) + 1)).astype(np.float32) * np.exp(-th / 0.018)
    tc = np.arange(int(0.25 * sr)) / sr
    clap = rng.standard_normal(len(tc)).astype(np.float32) * np.exp(-tc / 0.06)
    clap = np.convolve(clap, np.ones(6) / 6, "same")
    roots = [55.0, 55.0, 65.41, 49.0]  # A1 A1 C2 G1 (2 小節ずつ)

    total_beats = int(DURATION / BEAT) + 1
    drop = 6  # 6 拍目 (2.88s) でドロップ
    for b in range(total_beats):
        tb = beat(b)
        if b >= drop and tb < DURATION - 0.6:
            add(kick, tb, 0.9)
            if b % 2 == 1:
                add(clap, tb, 0.28)
            # 8 分のベース (サイドチェイン風に裏で鳴らす)
            f = roots[((b - drop) // 8) % len(roots)]
            tbs = np.arange(int(BEAT / 2 * sr)) / sr
            bass = np.tanh(2.5 * np.sin(2 * np.pi * f * tbs)) * np.sin(np.pi * tbs / (BEAT / 2)) ** 0.5
            add(bass.astype(np.float32), tb + BEAT / 2, 0.32)
        add(hat, tb + BEAT / 2, 0.16 if b >= 2 else 0.06)
        if b >= drop:
            add(hat, tb + BEAT * 0.25, 0.06)
            add(hat, tb + BEAT * 0.75, 0.06)

    # ドロップ前のライザー (フィルタが開いていくノイズ)
    rl = int(beat(drop) * sr)
    rise = rng.standard_normal(rl).astype(np.float32)
    env = np.linspace(0, 1, rl, dtype=np.float32) ** 2.5
    k = 24
    smooth = np.convolve(rise, np.ones(k) / k, "same")
    out[:rl] += (smooth + (rise - smooth) * env) * env * 0.22
    # エンディングのインパクト
    ti = np.arange(int(1.6 * sr)) / sr
    impact = (np.sin(2 * np.pi * 38 * ti) * 0.8 + rng.standard_normal(len(ti)) * 0.15) * np.exp(-ti / 0.5)
    add(impact.astype(np.float32), T_END, 0.6)

    out *= np.minimum(1, (DURATION - np.arange(n) / sr) / 0.4).astype(np.float32)  # フェードアウト
    out = np.tanh(out * 1.2) * 0.8
    return np.stack([out, out], axis=1)


# ════════════════════════════════════════════════════════════════════════════
# エントリーポイント
# ════════════════════════════════════════════════════════════════════════════


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", default="input.mov", type=Path)
    ap.add_argument("-o", "--output", default="promo.mp4", type=Path)
    ap.add_argument("--src-start", type=float, default=0.0, help="録画のどこから使うか (秒)")
    ap.add_argument("--src-speed", type=float, default=2.0, help="録画の再生速度 (2 = 2 倍速)")
    ap.add_argument("--music", type=Path, help="BGM ファイル (省略時は 125BPM の BGM を合成)")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--preview", type=float, metavar="SEC", help="指定秒の 1 フレームだけ PNG 出力")
    args = ap.parse_args()

    promo = Promo(args.input, args.src_start, args.src_speed)
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
            audio = AudioArrayClip(synth_bgm(), fps=44100)
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
