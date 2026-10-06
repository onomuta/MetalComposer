# Metal Composer

Quartz Composer をモダンに作り直すことを目指した、macOS 向けのノードベース・リアルタイムビジュアル環境です。SwiftUI と Metal で書いています。

> **注記**：Apple Inc. とは関係のない、個人による非公式のプロジェクトです。Metal、Quartz Composer、macOS は Apple Inc. の商標です。

## ビルドと起動

```bash
swift run                      # 開発用にそのまま起動
swift test                     # テスト（保存と読み込み、マクロ化、ペースト、数式）
./Scripts/bundle.sh            # build/Metal Composer.app を作成（release）
./Scripts/make-icon.sh         # アプリアイコンを再生成（Scripts/make-icon.swift → Assets/AppIcon.icns）
```

動作要件は macOS 14 以降と Xcode 16 以降のツールチェーンです。

### 配布用のビルド

```bash
# Apple silicon と Intel 両対応の .app を Developer ID で署名（Hardened Runtime）
VERSION=0.1.0 UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: Takao Onomura (BWZ7Q5QLJ5)" ./Scripts/bundle.sh release
# 公証してチケットを添付し、zip にする（初回のみ notarytool store-credentials が必要。スクリプト冒頭を参照）
./Scripts/notarize.sh 0.1.0
```

`SIGN_IDENTITY` を付けない場合はアドホック署名になり、手元で使う分には問題ありません。マイクを使うため、Hardened Runtime の entitlement（`Scripts/MetalComposer.entitlements`）で音声入力を許可しています。公証していない Developer ID 署名版は、ダウンロード後の初回起動時に macOS にブロックされます。

## 操作方法

| 操作 | 方法 |
|---|---|
| パッチの追加 | 左のライブラリをクリック、またはキャンバスを右クリック。⌘↩ でライブラリを開いて検索欄にフォーカスし、↑↓ で選んで Return で追加（追加するとライブラリは閉じます）。ライブラリが開いているときに ⌘↩ を押すと閉じます |
| ライブラリの開閉 | ツールバーのサイドバーボタン、または ⌥⌘L。開閉しても右カラムの幅は変わらず、中央のエディタの幅だけが変わります |
| カラム幅 | ライブラリと右カラムの境界をドラッグして変更できます（幅は次回起動時も保たれます） |
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
| プレビューの比率 | ビューア右上の比率メニューで、Free（領域いっぱい）、16:9、4:3、1:1、9:16、21:9、3:2 を選べます。比率を固定すると、余った部分は暗い帯になります。設定はポップアウトしたビューアと共通で、次回起動時も保たれます |
| ビューアのポップアウト | ビューア右上のボタン、または View › Pop Out Viewer（⌥⌘V）で別ウィンドウにします。サイズは自由に変えられ、フルスクリーン（⌃⌘F）にもできるので、プロジェクターへの出力に使えます。ウィンドウを閉じるか「Bring Back」で元に戻ります。描画するビューアは常に 1 つなので、時間やパーティクルが二重に進むことはありません |
| ファイル | ⌘N 新規、⌘O 開く、⌘S 保存（`.mcomp` = JSON）。File › Demos にサンプルが 7 つあります |
| 動画の書き出し | File › Export Movie…（⇧⌘E）。長さ、解像度（プリセットまたは任意）、フレームレート、コーデック（H.264／HEVC／ProRes 422 HQ／ProRes 4444〈アルファ付き〉）、画質を指定できます。t = 0 から各フレームの正確な時刻で 1 枚ずつ描くので、コマ落ちせず、毎回同じ結果になります。編集中の状態には影響せず、書き出し中はビューアを止めます |

## マクロ、Iterator、Render In Image

- **Macro**：中に置いた **Macro Input／Macro Output** が、マクロのポートになります。ポート名はパッチ名、型はインスペクタで選びます。並び順は Y 座標の順です。中にコンシューマがあれば、マクロ自体がレイヤを持ちます。
- **Iterator**：中身を 1 フレームに N 回実行します。**Iterator Variables** で、現在のインデックス、回数、位置（0〜1）を取得できます。
- **Render In Image**：中身を画面ではなくテクスチャに描画し、画像として出力します。出力を自分自身の画像入力につなぐと**フィードバック**になり、入力側には前フレームの画像が入ります（テクスチャ 2 枚を交互に使っています）。デモ「Feedback Trails」を参照してください。
- **3D Transformation**：中で描画したものに、移動・回転・拡大縮小を 3D でかけます（回転は X→Y→Z の順）。入れ子にすると変換が掛け合わされるので、階層構造を作れます。

## 設定

- **外観**：Metal Composer › Settings…（⌘,）で、ライト／ダーク／システムの設定に従う、を選べます。グラフのキャンバスは、どれを選んでも暗い色のままです。

## 時間の扱い（Time Base）

Quartz Composer と同じく、時間で動くパッチ（Patch Time、LFO、Interpolation、Random、Math Expression、Smooth、Integrator、Particle System、Metal Shader、各マクロ）には、インスペクタに **Time Base** の設定があります。

- **Parent**（既定）：親の時間（ルートなら再生時間）で動きます。
- **Local**：そのパッチが動き始めた時点を 0 として数えます。
- **External**：**Patch Time** 入力が増え、つないだ値がそのパッチの時間になります。止める（一定の値）、巻き戻す（減る値）、スクラブ（任意の値）ができます。マクロを External にすると、中身全体の時間をまとめて操れます。

**Integrator** は Value（1 秒あたりの変化量）× 経過時間を足し込みます。一時停止中は変わらず、External で時間を戻すと戻した分だけ引かれます。Reset がオンの間は 0 です。

**Particle System** は時間の関数として計算するので、External で時間を止める・巻き戻す・飛ばすことができ、同じ時刻なら必ず同じ絵になります。動画の書き出しでも、毎回同じ結果になります。粒の寿命や散らばりは、生まれた順の番号ごとに決まった乱数（Random Seed で変更可）で決まります。放出位置・色・大きさなどは履歴（直近 120 秒）として記録するので、動くエミッターの軌跡も正しく巻き戻ります。粒は生まれたときの色と大きさを保つので、Color や Size を変えると新しい粒から変わり、色や大きさの帯ができます。Iterator の中で反復ごとに Patch Time をずらすと、1 つのパッチで別々のパーティクルシステムを描けます（QC と同じ使い方です）。デモ「Time Rewind」を参照してください。

## 数値と論理

- **Conditional**：2 つの数値を比べます（等しい、等しくない、より大きい、より小さい、以上、以下）。「等しい」は Tolerance 以内の差を許します。
- **Logic**：2 つの真偽値を AND／OR／XOR／NAND／NOR で組み合わせます。NOT は First Value だけを反転します。
- **Range**：値を最小〜最大の範囲に収めます。範囲外の値は、端で止める（Clamp）、反対側から繰り返す（Wrap）、折り返す（Mirror）から選べます。
- **Map Range**：ある範囲の値を別の範囲に変換します（例：0〜1 を -1〜1 に）。Clamp をオンにすると、出力が変換先の範囲を超えません。
- **Round**：四捨五入（Round）、切り捨て（Floor）、切り上げ（Ceil）、0 方向への切り捨て（Truncate）をします。Step を指定すると、その倍数に丸めます（例：Step 0.25 なら 0.25 刻み）。

## Structure（配列）

- **Structure**：値の並び（配列）です。各要素には、任意でキー（名前）を付けられます。中身には数値・文字列・画像・Structure など何でも入ります。ポートの色はオレンジです。
- **Virtual（グレーのポート）**：どの型でもそのまま受け渡すポートです（QC の virtual ポート）。行き先の型に合わせて変換されます。普通の値を Structure の入力につなぐと、要素が 1 つの Structure として扱われます。
- **Structure Maker**：入力の数（Inputs）とキー（カンマ区切り）を設定でき、入力をまとめて 1 つの Structure にします。
- **Structure Index Member／Key Member**：番号（0 から始まる）またはキーで、要素を 1 つ取り出します。該当する要素がないときは何も出力しません。
- **Structure Count**：要素の数を出力します。
- **Queue**：入力を毎フレーム（または値が変わったときだけ）追加し、Size を超えると古いものから捨てます。順序は「古い順」と「新しい順」から選べます。Filling で追加を一時停止、Reset で空にします。画像は GPU 上でコピーして保持するので、Render In Image のように毎フレーム同じテクスチャを使い回すパッチの出力でも、各要素がそれぞれのフレームを保ちます（ビデオディレイなどに使えます）。
- **Multiplexer**：複数の入力のうち、Source Index（0 から始まる番号）で選んだ 1 つを出力します。**Demultiplexer**：1 つの入力を、Destination Index で選んだ出力に送ります。選ばれていない出力は「最後の値を保持」か「初期値に戻す」を選べます。どちらもポート数（2〜64）と型（既定は Virtual）を設定でき、番号が範囲外のときは端の番号に丸めます。
- デモ「Structures & Queue」：位置を {x, y} の Structure にして Queue で 60 フレーム分ため、Iterator で軌跡として描きます。

## オーディオ

- **Audio Input**：マイク（OS の既定の入力）の Volume Peak、Level（RMS）、Waveform（Structure、点の数は設定可）、Active を出力します。Gain と Release（下がるときの時定数）を指定できます。
- **Audio Spectrum**：FFT（2048 点、Hann 窓）で解析した周波数帯ごとの値を 0〜1 で出力します。帯は対数間隔で、数・下限と上限の周波数・Floor（dB）を設定できます。出力は Spectrum（Structure）、Bass／Mid／Treble、Image（帯の数 × 1px の画像）です。Image は Metal Shader の Image 入力や Sprite にそのまま渡せます。
- マイクは、どちらかのパッチが使われているときだけ動き、使われなくなって約 3 秒で止まります。初回は macOS がマイクの使用許可を求めます（`./Scripts/bundle.sh` で作った .app には説明文が入っています）。許可されていない、入力デバイスがない、といった理由で音が取れないときは、パッチに赤い点が付き、インスペクタに理由が表示されます。
- デモ「Audio Reactive」：スペクトルを Iterator で棒グラフにし、低音に合わせて図形が脈打ちます。
- 動画の書き出し中も、マイクからはライブの音を読みます（音声ファイルの解析は未対応）。

## Sprite、Billboard、Cube、Cylinder、Sphere

- **Billboard**：2D の板で、常に画面の正面を向きます（QC の Billboard と同じ）。3D Transformation の中では位置だけが変換に従います。
- **Sprite**：3D 空間に置く板です。X/Y/Z 位置と X/Y/Z 回転を指定でき、遠近がつきます。
- **Cube**：3D 空間に置く箱です（QC の Cube と同じ）。位置・回転・幅／高さ／奥行きを指定でき、Front／Back／Left／Right／Top／Bottom の面ごとに色と画像を設定できます。面の画像は、その面を正面から見たときに正しい向きになります。
- **Cylinder**：3D 空間に置く円柱です（QC の Cylinder と同じ）。上と下の半径を別々に指定でき、片方を 0 にすると円錐になります。側面の画像は一周巻き付き、画像の中央が正面に来ます。上下のふたには別の色と画像を設定でき、Cube の Top／Bottom と同じ向きになります。なめらかさは Segments（既定 64）で変えられます。
- **Sphere**：3D 空間に置く球です（QC の Sphere と同じ）。画像は正距円筒図法（緯度経度の地図、2:1 のパノラマなど）として巻き付き、画像の上端が北極、中央が正面に来ます。地球のテクスチャや 360° 写真をそのまま使えます。なめらかさは Segments（既定 64）で変えられます。
- **座標系**：z = 0 の平面では、x は -1〜1、y は ±(高さ/幅) です（従来と同じ）。カメラは z = 2 に固定で、+z が手前です。
- **深度**：Sprite、Billboard、Cube、Cylinder、Sphere には「Depth Test」の設定があります（既定は Billboard だけオフ、ほかはオン）。パーティクルは深度を読むだけで書き込みません。Clear は深度もリセットします。比較は lessEqual なので、同じ z に並ぶ 2D のレイヤはこれまでどおりレイヤ順に重なります。半透明の面は深度に書き込まない（Depth Test をオフにする）か、Add ブレンドにしてください。

## アーキテクチャ

```
Sources/
├─ MetalComposerKit/      描画エンジン（他のアプリに組み込む部品。エディタの UI は含まない）
│  ├─ Core/               Value・PortSpec・Patch の基底クラス、Graph（入れ子にできるグラフと保存形式）、
│  │                      Evaluator（プル型評価）、Demos、MathExpression のパーサ
│  ├─ Patches/            Providers／Processors／Image／Consumers／Macros／Structures／Audio の各パッチ
│  ├─ Render/             RenderResources、FrameRenderer（1 フレームの描画）、ShaderLibrary（MSL）、Camera、MovieExporter
│  └─ Public/             他のアプリ向けの公開 API（CompositionPlayer）
├─ MetalComposerEditor/   エディタ（SwiftUI の画面、Composition＝ドキュメントと Undo、ビューア）
└─ MetalComposer/         エディタを起動するだけの実行ファイル
```

エンジン内部の型は `package` 指定で、同じパッケージのエディタとテストからだけ使えます。外部のアプリに見えるのは `Public/` の API だけです。

- **評価モデル**：Quartz Composer と同じプル型です。`Evaluator` は 1 つの `Graph` を 1 フレーム評価します。コンシューマ（Clear、Sprite など）がレイヤ順に要求したパッチだけが、1 回ずつ実行されます（`Patch.execute` → 出力値と描画コマンド）。循環接続がある場合は、前フレームの値を返します。マクロは中のグラフに対して自分用の `Evaluator` を作り、公開入力の値を `EvalContext.published` で渡します。
- **描画**：フェーズ 1 でグラフを実行し、描画コマンド（`DrawCommand`）を集めます。オフスクリーンの処理（Render In Image、Core Image）は、このときにコマンドバッファへエンコードされます。フェーズ 2 で、ビューアのレンダーパスにコマンドを `#レイヤ番号` の順に再生します。コンシューマは `RenderContext.targetSize` を使って描画するので、画面にもテクスチャにも同じように描けます。
- **Undo**：編集のたびに、ドキュメントのスナップショット（`GraphRecord`）をドキュメント専用の `UndoManager` に積みます。スライダーのドラッグや文字入力のような連続した変更は、1 回の取り消しにまとめます。
- **Metal Shader パッチ**：`mainImage(uv, u, image, s)` を書くと、その場でコンパイルされます。エラーは行番号付きでインスペクタに表示されます。
- **座標系**：QC と同じく、x は -1〜1、y は ±(高さ/幅) です。

## 他のアプリへの組み込み（MetalComposerKit）

VJ アプリなどで `.mcomp` を素材として再生できます。Swift Package Manager で `MetalComposerKit` を追加します。

```swift
.package(url: "https://github.com/onomuta/MetalComposer.git", from: "0.3.0")
// ターゲットの依存に .product(name: "MetalComposerKit", package: "MetalComposer")
```

```swift
import MetalComposerKit

let engine = try MetalComposerEngine(device: device)          // デバイスごとに 1 つ作って使い回す
let player = try CompositionPlayer(engine: engine, contentsOf: url)

for p in player.parameters { print(p.name, p.type, p.defaultValue) }   // 作品のトップに置いた Macro Input
player.setValue(.number(0.8), forParameter: player.parameters[0].key)

// 毎フレーム：ホストの command buffer の中で、bgra8Unorm のテクスチャに描く
player.encode(into: layerTexture, time: layerTime, commandBuffer: commandBuffer, clearAlpha: 0)
```

- **スレッド**：メインスレッドで使います（エディタと同じ前提）。
- **時間**：`time` は作品自身の時計（秒）です。止める・飛ばす・戻すことができ、パーティクルなどもそれに従います。最初からやり直すときは `restart()` を呼びます。
- **パラメータ**：作品のトップに置いた **Macro Input** が公開パラメータになります。エディタでは Macro Input の「Default Value」で既定値を決められます。
- **ファイルの場所**：Image Importer のファイルは、作品と同じフォルダの中に置くと相対パスで保存されます。作品のフォルダごと素材フォルダに移しても、そのまま読めます。
- **Text Image のフォント**：インスペクタの **Font** で、Mac に入っているフォントをファミリーとスタイル（Light、Bold など）から選べます。System Font のときだけ Weight が使えます。フォントは名前で保存されるので、作品を開く Mac にも同じフォントが入っている必要があります。入っていなければシステムフォントで描き、その旨を表示します（組み込み先では `problems` に出ます）。
- **画像の埋め込み**：Image Importer の **Embed in Composition** をオンにすると、画像ファイルの中身を作品に保存します。元のファイルがなくても、作品 1 つで持ち運べます。読み込みはファイルより 2〜3 倍遅く、作品も画像より 3 割ほど大きくなるので、ロゴやテクスチャなど数 MB までの画像に向いています（10MB を超えるとインスペクタに注意が出ます）。埋め込み後に元のファイルを変えても作品には反映されないので、反映するにはファイルを選び直します。0.4.1 以前の版で開くと、埋め込んだ画像は使われず、ファイルから読みます。
- **問題の確認**：画像が見つからない、シェーダのエラーなどは `problems` で取得できます。新しい Metal Composer で追加されたパッチなど、このエンジンが知らないパッチは読み飛ばし（つながりも外れます）、その種類を `problems` に含めます。エディタで開いたときは警告を出します。
- **Mouse パッチ**：組み込み先では、位置が常に中央になります。
- **ファイル形式**：エンジンより新しい形式の作品を読もうとすると、読み込みの段階でエラーになります（`CompositionPlayer.supportedFormatVersion`）。

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

## ライセンス

[MIT License](LICENSE)
