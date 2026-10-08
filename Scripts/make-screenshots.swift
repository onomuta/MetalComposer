// Composes the App Store screenshots: each raw simulator capture in iOS/AppStore/Raw, framed on the
// app icon's background with a caption above it, at the sizes App Store Connect asks for, in each
// App Store language (iOS/AppStore/Screenshots/<language>/<device>).
// Usage: swift Scripts/make-screenshots.swift   (run from the repository root)
//
// Raw captures (kept locally, not in the repository: see .gitignore): iPhone 17 Pro Max (portrait, 1320×2868) and iPad Pro 11-inch in landscape, which
// simctl saves rotated into a portrait image (it is turned back here).
import AppKit
import CoreGraphics
import CoreText

struct Shot {
    var raw: String
    var caption: String
    var subtitle: String
}

/// Output sizes: 6.9" and 6.3" iPhone portrait (App Store Connect now asks for the 6.3" set first),
/// 13" iPad landscape, Mac (16:10).
let iPhoneSize = CGSize(width: 1320, height: 2868)
let iPhoneMediumSize = CGSize(width: 1206, height: 2622)
let iPadSize = CGSize(width: 2752, height: 2064)
let macSize = CGSize(width: 2880, height: 1800)

/// Captions per App Store localization; each list matches the raw captures in order.
struct Language {
    var code: String
    var iPhone: [Shot]
    var iPad: [Shot]
    /// Mac window captures, in Raw/Mac-<code> (the app's own language differs, unlike iOS).
    var mac: [Shot]
    /// Font for the caption and subtitle; nil is the system font.
    var bold: String?
    var medium: String?
}

let iPhoneShots = [
    Shot(raw: "01-play", caption: "Real-time visuals,\nin your pocket", subtitle: "Play node-based compositions at up to 120 fps"),
    Shot(raw: "02-editor", caption: "Wire patches into\nliving graphics", subtitle: "The same editor as the Mac app"),
    Shot(raw: "03-inspector", caption: "Tune every value,\nwatch it change", subtitle: "A live preview stays in view while you edit"),
    Shot(raw: "04-cube", caption: "2D, 3D, particles\nand shaders", subtitle: "Build it all from patches"),
]
let iPadShots = [
    Shot(raw: "01-play", caption: "Real-time visuals on iPad", subtitle: "Play compositions full screen, or on an external display"),
    Shot(raw: "02-editor", caption: "The full node editor, made for touch", subtitle: "Library, graph, viewer and inspector side by side"),
    Shot(raw: "03-cube", caption: "2D, 3D, particles and shaders", subtitle: "Build it all from patches"),
]

let macShots = [
    Shot(raw: "01-editor", caption: "A node editor for real-time visuals", subtitle: "Wire patches, tune values and watch the result live"),
    Shot(raw: "02-viewer", caption: "Take it full screen", subtitle: "Pop out the viewer onto a projector or a second display"),
    Shot(raw: "03-export", caption: "Export flawless movies", subtitle: "H.264, HEVC and ProRes, rendered frame by frame"),
]

let japanese = Language(
    code: "ja",
    iPhone: [
        Shot(raw: "01-play", caption: "リアルタイム映像を\nポケットに", subtitle: "ノードで組んだ作品を最大 120fps で再生"),
        Shot(raw: "02-editor", caption: "パッチをつないで\n動く映像をつくる", subtitle: "Mac 版と同じエディタ"),
        Shot(raw: "03-inspector", caption: "値を変えると\nすぐに見える", subtitle: "編集中もプレビューが見えたまま"),
        Shot(raw: "04-cube", caption: "2D も 3D も\nパーティクルも", subtitle: "シェーダーまで、すべてパッチの組み合わせで"),
    ],
    iPad: [
        Shot(raw: "01-play", caption: "iPad でリアルタイム映像", subtitle: "全画面で再生、外部ディスプレイにも出力"),
        Shot(raw: "02-editor", caption: "フル機能のノードエディタを、タッチで", subtitle: "ライブラリ・グラフ・ビューア・インスペクタを一画面に"),
        Shot(raw: "03-cube", caption: "2D・3D・パーティクル、そしてシェーダー", subtitle: "すべてパッチの組み合わせで"),
    ],
    mac: [
        Shot(raw: "01-editor", caption: "リアルタイム映像のノードエディタ", subtitle: "パッチをつないで、値を変えて、その場で確かめる"),
        Shot(raw: "02-viewer", caption: "フルスクリーンで上映", subtitle: "ビューアを別ウインドウにして、プロジェクターや外部ディスプレイへ"),
        Shot(raw: "03-export", caption: "コマ落ちしないムービー書き出し", subtitle: "H.264・HEVC・ProRes を 1 フレームずつ正確に描画"),
    ],
    bold: "HiraginoSans-W7", medium: "HiraginoSans-W5")

let languages = [
    Language(code: "en-US", iPhone: iPhoneShots, iPad: iPadShots, mac: macShots, bold: nil, medium: nil),
    japanese,
]

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Can't read \(path)") }
    return image
}

/// Turns a landscape iPad capture (stored rotated into portrait) the right way up.
func rotatedClockwise(_ image: CGImage) -> CGImage {
    let w = image.height, h = image.width
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.rotate(by: -.pi / 2)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

/// Draws centered text in a box whose top is `top` (top-left coordinates); returns the bottom.
func drawText(_ text: String, in ctx: CGContext, canvas: CGSize, top: CGFloat, size: CGFloat, weight: NSFont.Weight,
              fontName: String?, color: CGColor, width: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = size * 0.08
    let attributed = NSAttributedString(string: text, attributes: [
        .font: fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color)!,
        .paragraphStyle: style,
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                           CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    // Core Text draws bottom-up; the canvas is bottom-up too.
    let rect = CGRect(x: (canvas.width - width) / 2, y: canvas.height - top - ceil(fit.height),
                      width: width, height: ceil(fit.height))
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return top + ceil(fit.height)
}

func compose(_ shot: Shot, device: String, canvas: CGSize, landscape: Bool, language: Language, rawFolder: String? = nil) {
    var image = loadImage("iOS/AppStore/Raw/\(rawFolder ?? device)/\(shot.raw).png")
    if landscape, image.height > image.width { image = rotatedClockwise(image) }

    let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Background: the app icon's indigo with a magenta and a cyan glow.
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0x2C3180), rgb(0x0C0C24)] as CFArray, locations: nil)!,
                           start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: 0, y: 0), options: [])
    for (hex, alpha, x, y, r) in [(UInt32(0xB040FF), 0.45, 0.8, 0.75, 0.7), (0x30D5FF, 0.25, 0.15, 0.3, 0.6)] {
        let center = CGPoint(x: canvas.width * x, y: canvas.height * y)
        ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(hex, alpha), rgb(hex, 0)] as CFArray, locations: nil)!,
                               startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: max(canvas.width, canvas.height) * r, options: [])
    }

    // Caption.
    let unit = min(canvas.width, canvas.height)
    let margin = unit * 0.07
    var y = landscape ? unit * 0.06 : unit * 0.11
    y = drawText(shot.caption, in: ctx, canvas: canvas, top: y, size: unit * (landscape ? 0.058 : 0.085),
                 weight: .bold, fontName: language.bold, color: rgb(0xFFFFFF), width: canvas.width - margin * 2)
    y += unit * 0.02
    y = drawText(shot.subtitle, in: ctx, canvas: canvas, top: y, size: unit * (landscape ? 0.03 : 0.04),
                 weight: .medium, fontName: language.medium, color: rgb(0xFFFFFF, 0.75), width: canvas.width - margin * 2)

    // The screen, as large as fits under the caption, with rounded corners and a soft shadow.
    let top = y + unit * (landscape ? 0.05 : 0.07)
    let available = CGSize(width: canvas.width - margin * 2, height: canvas.height - top - unit * 0.06)
    let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let rect = CGRect(x: (canvas.width - size.width) / 2, y: unit * 0.06 + (available.height - size.height),
                      width: size.width, height: size.height)
    let corner = unit * (landscape ? 0.03 : 0.07)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.012), blur: unit * 0.05, color: rgb(0x000000, 0.6))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: rect)
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(unit * 0.003)
    ctx.strokePath()

    let folder = "iOS/AppStore/Screenshots/\(language.code)/\(device)"
    let out = "\(folder)/\(shot.raw).png"
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("Wrote \(out) (\(Int(canvas.width))×\(Int(canvas.height)))")
}

for language in languages {
    for shot in language.iPhone {
        compose(shot, device: "iPhone", canvas: iPhoneSize, landscape: false, language: language)
        compose(shot, device: "iPhone-6.3", canvas: iPhoneMediumSize, landscape: false, language: language, rawFolder: "iPhone")
    }
    for shot in language.iPad { compose(shot, device: "iPad", canvas: iPadSize, landscape: true, language: language) }
    let macFolder = "Mac-" + (language.code == "en-US" ? "en" : language.code)
    for shot in language.mac {
        compose(shot, device: "Mac", canvas: macSize, landscape: true, language: language, rawFolder: macFolder)
    }
}
