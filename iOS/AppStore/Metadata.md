# App Store metadata

Text for App Store Connect, in English (U.S.) and Japanese. The same text works for the iOS and the
macOS version; each has its own fields in App Store Connect, so paste it into both.

Limits: name and subtitle 30 characters, promotional text 170, keywords 100 (comma-separated, no
spaces needed), description 4000, What's New 4000.

---

## What's New

Paste into "What's New in This Version" for both the iOS and the macOS version.

### 1.0.1 — English (U.S.)

```
• Image Importer can now make white shapes without an image file: circle, ring, soft dot, square, frame, triangle, star, cross and line, with adjustable line width and glow.
• New Text Characters patch: takes a string apart one character at a time and tells where Text Image places each one, for letter-by-letter animation inside an Iterator.
• New ONOM FLOW Input patch: when a composition plays inside a VJ app that supports it, the patch receives that app's BPM, beat, gain, Input 1–4, texts, images and colors. In Mirage Composer you can try the values in the viewer's Parameters.
• Macro Input can limit a number to a minimum and maximum. The macro's slider uses the range, and values are kept inside it.
• Audio Input and Audio Spectrum react much faster and more smoothly.
• ⌘↩ (Mac and hardware keyboards) moves to the patch search first; pressed again there, it closes the library.
• .mcomp files have their own document icon.
```

### 1.0.1 — Japanese

```
• Image Importer で、画像ファイルなしで白い図形を使えるようになりました。円、リング、ソフトドット、四角、枠、三角、星、十字、線から選べ、線の太さとグローも調整できます。
• 新しい Text Characters パッチ：文字列から 1 文字ずつ取り出し、Text Image で置かれる位置もわかります。Iterator と組み合わせて、文字を 1 つずつ動かせます。
• 新しい ONOM FLOW Input パッチ：対応する VJ アプリで作品を再生したとき、そのアプリから BPM、ビート、ゲイン、Input 1〜4、テキスト、画像、色を受け取ります。Mirage Composer では、ビューアのパラメータで値を試せます。
• Macro Input で、数値の最小値と最大値を設定できるようになりました。マクロのスライダーがその範囲になり、値も範囲内に収まります。
• Audio Input と Audio Spectrum が、音に遅れず、なめらかに反応するようになりました。
• ⌘↩（Mac と外付けキーボード）で、まずパッチ検索の欄に移ります。検索欄でもう一度押すとライブラリを閉じます。
• .mcomp ファイルに専用のアイコンを付けました。
```

---

## English (U.S.)

**Name:** Mirage Composer

**Subtitle:** Node-based real-time visuals

**Promotional text:**

Wire patches together and watch living graphics appear in real time. A node editor for visuals on iPhone, iPad and Mac, free with no ads or sign-in.

**Keywords:**

```
VJ,visuals,node,shader,generative,motion graphics,live,projection,audio reactive,particles,3D,art
```

**Description:**

```
Mirage Composer is a node-based editor and player for real-time visuals. Connect patches in a graph — generators, filters, 2D shapes, 3D objects, particles, text and more — and the result plays live as you build it.

BUILD WITH PATCHES
• Drag patches into the graph and wire their outputs to inputs
• 2D shapes, gradients, noise, images and text
• 3D objects with cameras and lights
• Particles, feedback, blur, color and blend filters
• Write your own Metal shader for anything else
• Audio patches that make visuals react to sound from the microphone

SEE EVERY CHANGE
• The viewer renders at your display's full frame rate, up to 120 fps on ProMotion displays
• Tune values in the inspector and watch them change instantly
• Publish parameters and adjust them while the composition plays

ON IPHONE AND IPAD
• The full editor, designed for touch: long-press for menus, pinch to zoom the graph
• On iPhone, keep a small floating preview in view while you edit
• Play compositions full screen, or send them to an external display or projector
• Compositions are files you keep: open them from the Files app, iCloud Drive or AirDrop

ON MAC
• Pop out the viewer onto a projector or a second display
• Export movies in H.264, HEVC or ProRes, rendered frame by frame with no dropped frames

The same composition files open on iPhone, iPad and Mac. Demo compositions are included to get you started.

No ads, no accounts, no tracking. Your work stays on your devices.
```

**Support URL:** https://onomuta.github.io/MetalComposer/support/
**Privacy Policy URL:** https://onomuta.github.io/MetalComposer/privacy/
**Copyright:** 2026 Takao Onomura

---

## Japanese

**名前:** Mirage Composer

**サブタイトル:** ノードでつくるリアルタイム映像

**プロモーション用テキスト:**

パッチをつなぐと、動く映像がその場で生まれる。iPhone・iPad・Mac で使える映像のためのノードエディタ。無料、広告もアカウント登録もありません。

**キーワード:**

```
VJ,映像,ノード,シェーダー,ジェネラティブ,モーショングラフィックス,リアルタイム,プロジェクション,音に反応,パーティクル,3D,アート,ビジュアル,メディアアート
```

**概要:**

```
Mirage Composer は、リアルタイム映像のためのノードエディタ兼プレーヤーです。ジェネレータ、フィルタ、2D の図形、3D オブジェクト、パーティクル、テキストなどのパッチをグラフの上でつなぐと、つくっている途中の映像がそのまま動き続けます。

パッチを組み合わせてつくる
・パッチをグラフに置いて、出力を入力につなぐだけ
・2D の図形、グラデーション、ノイズ、画像、テキスト
・カメラとライトのある 3D オブジェクト
・パーティクル、フィードバック、ぼかし、色調整、合成のフィルタ
・足りないものは Metal シェーダーを書いて自作
・マイクの音に反応させるオーディオパッチ

変更がすぐに見える
・ビューアはディスプレイのフレームレートで描画（ProMotion なら最大 120fps）
・インスペクタで値を変えると、その場で映像に反映
・パラメータを公開して、再生しながら調整

iPhone と iPad で
・フル機能のエディタをタッチ操作で。長押しでメニュー、ピンチでグラフを拡大縮小
・iPhone では、小さなプレビューを浮かべたまま編集
・全画面で再生、外部ディスプレイやプロジェクターにも出力
・作品はファイルとして保存。ファイルアプリ、iCloud Drive、AirDrop でやりとり

Mac で
・ビューアを別ウインドウにして、プロジェクターや外部ディスプレイで上映
・H.264・HEVC・ProRes でムービーを書き出し。1 フレームずつ描画するのでコマ落ちしません

同じ作品ファイルを iPhone・iPad・Mac で開けます。すぐに試せるデモ作品も入っています。

広告、アカウント、トラッキングは一切ありません。作品はあなたの端末の中に残ります。
```

**サポート URL:** https://onomuta.github.io/MetalComposer/support/
**プライバシーポリシー URL:** https://onomuta.github.io/MetalComposer/privacy/
**著作権:** 2026 Takao Onomura

---

## App Review notes (English)

```
Mirage Composer is a free node-based editor and player for real-time visuals. No account or sign-in is needed, and the app makes no network requests.

Getting started: on the home screen, open any of the bundled demo compositions to play it, or tap Edit to open it in the editor.

Microphone: the app asks for microphone access only when a composition contains an audio patch (Audio Input or Audio Spectrum). The sound is analyzed in memory to drive the visuals; it is never recorded, saved or transmitted. To see it, open the "Audio Reactive" demo.

Metal Shader patch: users can type GPU fragment shader code (Metal Shading Language) into this patch. The code is compiled on device by Metal and runs only on the GPU to compute pixel colors for that patch. It cannot call system APIs, it does not download anything, and it does not change the app's features or functionality, so it is consistent with guideline 2.5.2.

External display (iOS): when a display or projector is connected, the composition plays full screen on it while the device shows the controls.
```
