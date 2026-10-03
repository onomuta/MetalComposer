# Metal Composer

Quartz Composer をモダンに作り直すことを目指した、macOS 向けのノードベース・リアルタイムビジュアル環境です。SwiftUI と Metal で書いています。

## ビルドと起動

```bash
swift run                      # 開発用にそのまま起動
./Scripts/bundle.sh            # build/Metal Composer.app を作成（release）
```

動作要件は macOS 14 以降と Xcode 16 以降のツールチェーンです。

## 操作方法

| 操作 | 方法 |
|---|---|
| パッチの追加 | 左のライブラリをクリック、またはキャンバスを右クリック |
| 接続 | 出力ポートから入力ポートへドラッグ |
| 切断・つなぎ替え | 接続済みの入力ポートをドラッグして外す |
| パッチの移動・選択 | ノードをドラッグ／クリック |
| 削除 | 選択して Delete |
| パン／ズーム | 2本指スクロール（または背景をドラッグ）／ピンチ（または ⌘+スクロール）。右下の「Fit」で全体表示 |
| 再生 | ビューア上部のボタンで再生・一時停止・時間リセット（⌥⌘P） |
| ファイル | ⌘N 新規、⌘O 開く、⌘S 保存（`.mcomp` = JSON） |

## アーキテクチャ

```
Sources/MetalComposer/
├─ Core/       Value・PortSpec・Patch の基底クラス、Composition（グラフと保存）、
│              Evaluator（プル型評価）、MathExpression のパーサ
├─ Patches/    Providers / Processors / Image / Consumers の各パッチ
├─ Render/     RenderResources（パイプラインとシェーダキャッシュ）、Renderer、ShaderLibrary（MSL）
└─ Editor/     グラフキャンバス、インスペクタ、ライブラリ、ビューア
```

- **評価モデル**：Quartz Composer と同じプル型です。コンシューマ（Clear、Sprite など）がレイヤ順に入力を要求し、そこにつながる上流のパッチだけが実行されます。各パッチは 1 フレームにつき 1 回だけ実行され、結果はキャッシュされます。循環接続がある場合は、前フレームの値を返します。
- **描画**：毎フレーム、まずすべての入力を解決します（Core Image フィルタはこの段階でコマンドバッファにエンコードされます）。その後 1 つのレンダーパスで、コンシューマを `#レイヤ番号` の順に描画します。
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

- Undo/Redo、複数選択、コピー＆ペースト、ノードのコメント
- マクロパッチ（サブグラフ）と公開ポート、Iterator／Replicator
- Render In Image（オフスクリーン描画を画像出力にする）、フィードバック
- Video Input（AVFoundation）、Audio Spectrum、MIDI／OSC 入力
- 3D（Mesh、Camera、Lighting）、Compute Shader パッチ
- ポート上での値の表示、フルスクリーン表示、録画（ProRes/HEVC への書き出し）
- Syphon 互換の出力
