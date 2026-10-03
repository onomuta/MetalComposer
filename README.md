# Metal Composer

Quartz Composer をモダンに作り直すことを目指した、macOS 向けのノードベース・リアルタイムビジュアル環境です。SwiftUI と Metal で書いています。

## ビルドと起動

```bash
swift run                      # 開発用にそのまま起動
swift test                     # テスト（保存と読み込み、マクロ化、ペースト、数式）
./Scripts/bundle.sh            # build/Metal Composer.app を作成（release）
```

動作要件は macOS 14 以降と Xcode 16 以降のツールチェーンです。

## 操作方法

| 操作 | 方法 |
|---|---|
| パッチの追加 | 左のライブラリをクリック、またはキャンバスを右クリック。⌘↩ でライブラリを開いて検索欄にフォーカスし、↑↓ で選んで Return で追加 |
| ライブラリの開閉 | ツールバーのサイドバーボタン、または ⌥⌘L |
| 接続 | 出力ポートから入力ポートへドラッグ |
| 切断・つなぎ替え | 接続済みの入力ポートをドラッグして外す |
| 選択 | クリック、背景をドラッグして範囲選択、Shift／⌘+クリックで追加・解除、⌘A ですべて選択 |
| 移動 | ノードをドラッグ（選択中のノードはまとめて移動） |
| 削除・複製 | Delete（または ⌦）で削除、⌘D で複製、⌘C／⌘X／⌘V でコピー・カット・ペースト。テキストの編集中は、テキストの操作になります |
| 取り消し | ⌘Z／⇧⌘Z（テキストを編集中は、テキストの取り消しになります） |
| マクロ | ⌘G で選択範囲をマクロにまとめる（境界をまたぐ接続は自動で公開ポートになります）。⇧⌘G で展開して元に戻す（通常の Macro のみ）。ダブルクリックか ⌘↓ で中に入り、Esc か ⌘↑ かパンくずリストで外に戻る |
| 値の調整 | インスペクタの数値の横にあるノブを上下（左右）ドラッグ。⌥ で微調整、⇧ で粗調整、ダブルクリックで初期値に戻します。スライダーとノブの範囲は**目安**で、値はその外にも出せます。止まるのは、Count が 1 以上のような**上限**（`PortSpec.limits`）だけです。位置と回転には目安の範囲がなく、スライダーなしのノブで何回転でも回せます（位置は 1pt で 0.005、角度は 1pt で 1°） |
| 値の確認 | ポートにカーソルを当てると、今の値がツールチップで表示されます（画像はサムネイル、色は色見本） |
| コメント | 右クリック › Add Comment Here、または ⌥⌘C。ダブルクリックで編集し、Esc か外側のクリックで確定します。右下の角をドラッグでサイズ変更、インスペクタで色を変更できます |
| パン／ズーム | 2本指スクロール（または ⌥+背景ドラッグ）／ピンチ（または ⌘+スクロール）。右下の「Fit」で全体表示 |
| 再生 | ビューア上部のボタンで再生・一時停止・時間リセット（⌥⌘P） |
| ファイル | ⌘N 新規、⌘O 開く、⌘S 保存（`.mcomp` = JSON）。File › Demos にサンプルが 4 つあります |

## マクロ、Iterator、Render In Image

- **Macro**：中に置いた **Macro Input／Macro Output** が、マクロのポートになります。ポート名はパッチ名、型はインスペクタで選びます。並び順は Y 座標の順です。中にコンシューマがあれば、マクロ自体がレイヤを持ちます。
- **Iterator**：中身を 1 フレームに N 回実行します。**Iterator Variables** で、現在のインデックス、回数、位置（0〜1）を取得できます。
- **Render In Image**：中身を画面ではなくテクスチャに描画し、画像として出力します。出力を自分自身の画像入力につなぐと**フィードバック**になり、入力側には前フレームの画像が入ります（テクスチャ 2 枚を交互に使っています）。デモ「Feedback Trails」を参照してください。
- **3D Transformation**：中で描画したものに、移動・回転・拡大縮小を 3D でかけます（回転は X→Y→Z の順）。入れ子にすると変換が掛け合わされるので、階層構造を作れます。

## Sprite と Billboard

- **Billboard**：2D の板で、常に画面の正面を向きます（QC の Billboard と同じ）。3D Transformation の中では位置だけが変換に従います。
- **Sprite**：3D 空間に置く板です。X/Y/Z 位置と X/Y/Z 回転を指定でき、遠近がつきます。
- **座標系**：z = 0 の平面では、x は -1〜1、y は ±(高さ/幅) です（従来と同じ）。カメラは z = 2 に固定で、+z が手前です。
- **深度**：Sprite と Billboard には「Depth Test」の設定があります（既定は Sprite がオン、Billboard がオフ）。パーティクルは深度を読むだけで書き込みません。Clear は深度もリセットします。比較は lessEqual なので、同じ z に並ぶ 2D のレイヤはこれまでどおりレイヤ順に重なります。半透明の面は深度に書き込まない（Depth Test をオフにする）か、Add ブレンドにしてください。

## アーキテクチャ

```
Sources/MetalComposer/
├─ Core/       Value・PortSpec・Patch の基底クラス、Composition（ドキュメント、Undo、マクロ化、クリップボード）、
│              Graph（入れ子にできるグラフと保存形式）、Evaluator（プル型評価）、
│              Demos、MathExpression のパーサ
├─ Patches/    Providers / Processors / Image / Consumers / Macros の各パッチ
├─ Render/     RenderResources（パイプラインとシェーダキャッシュ）、Renderer、ShaderLibrary（MSL）
└─ Editor/     グラフキャンバス、インスペクタ、ライブラリ、ビューア
```

- **評価モデル**：Quartz Composer と同じプル型です。`Evaluator` は 1 つの `Graph` を 1 フレーム評価します。コンシューマ（Clear、Sprite など）がレイヤ順に要求したパッチだけが、1 回ずつ実行されます（`Patch.execute` → 出力値と描画コマンド）。循環接続がある場合は、前フレームの値を返します。マクロは中のグラフに対して自分用の `Evaluator` を作り、公開入力の値を `EvalContext.published` で渡します。
- **描画**：フェーズ 1 でグラフを実行し、描画コマンド（`DrawCommand`）を集めます。オフスクリーンの処理（Render In Image、Core Image）は、このときにコマンドバッファへエンコードされます。フェーズ 2 で、ビューアのレンダーパスにコマンドを `#レイヤ番号` の順に再生します。コンシューマは `RenderContext.targetSize` を使って描画するので、画面にもテクスチャにも同じように描けます。
- **Undo**：編集のたびに、ドキュメントのスナップショット（`GraphRecord`）をドキュメント専用の `UndoManager` に積みます。スライダーのドラッグや文字入力のような連続した変更は、1 回の取り消しにまとめます。
- **Metal Shader パッチ**：`mainImage(uv, u, image, s)` を書くと、その場でコンパイルされます。エラーは行番号付きでインスペクタに表示されます。
- **座標系**：QC と同じく、x は -1〜1、y は ±(高さ/幅) です。

## パッチの追加方法

`Patch` を継承し、クラスプロパティ（`typeID`・`title`・`category`・`inputSpecs`・`outputSpecs`）を定義します。Provider と Processor では `evaluate`、Consumer では `render` を実装し、最後に `PatchRegistry.all` に登録します。

```swift
final class MyPatch: Patch {
    override class var typeID: String { "my-patch" }
    override class var title: String { "My Patch" }
    override class var inputSpecs: [PortSpec] { [.number("in", "Input", 0, 0...1)] }
    override class var outputSpecs: [PortSpec] { [.number("out", "Output")] }
    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["out": .number(i.number("in") * 2)]
    }
}
```

## ロードマップ案

- 既知の制限：Iterator の中にある状態を持つパッチ（Smooth、Particle、Core Image、Render In Image）は、すべての反復で 1 つのインスタンスを共有します
- Video Input（AVFoundation）、Audio Spectrum、MIDI／OSC 入力
- Mesh、Camera、Lighting、Compute Shader パッチ
- ポート上での値の表示、フルスクリーン表示、録画（ProRes/HEVC への書き出し）
- Syphon 互換の出力
