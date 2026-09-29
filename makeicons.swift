//  SplashMLX 图标生成器
//  用 CoreGraphics 程序化绘制，输出：
//    - AppIcon.iconset/*.png  → iconutil 打包成 AppIcon.icns
//    - menubar_{running,paused,stopped}[@2x|@3x].png
//  设计语言统一：水滴（Splash）+ 状态色 + 状态字形。

import Foundation
import CoreGraphics
import ImageIO

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default

// MARK: - 画布

/// 单位坐标画布：(0,0) 左上，(1,1) 右下，y 轴向下
func canvas(_ px: Int) -> CGContext? {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px), y: -CGFloat(px))
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: - 水滴路径

/// 经典水滴单路径：底部圆弧 + 两侧内凹曲线收拢到顶点。
/// 凹面（concavity>0）是水滴与"叶子"的关键区别。可填充也可描边，无内部接缝。
func addDroplet(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, apexY: CGFloat,
                concavity: CGFloat = 0.34) {
    let d = cy - apexY
    let ratio = r / d
    let baseY = cy - ratio * ratio * d          // 切点所在高度
    let off = ratio * sqrt(1 - ratio * ratio) * d

    let apex = CGPoint(x: cx, y: apexY)
    let p1 = CGPoint(x: cx + off, y: baseY)     // 右切点
    let p2 = CGPoint(x: cx - off, y: baseY)     // 左切点

    let t1 = atan2(baseY - cy, off)             // 右切点角（负）
    let t2 = atan2(baseY - cy, -off) + 2 * .pi  // 左切点角 +2π，保证绕经正下方

    ctx.beginPath()
    ctx.move(to: apex)
    // 右侧：凹曲线
    let m1 = CGPoint(x: (apex.x + p1.x) / 2, y: (apex.y + p1.y) / 2)
    ctx.addQuadCurve(to: p1, control: CGPoint(x: m1.x - concavity * (p1.x - cx), y: m1.y))
    // 底部圆弧（从右切点绕经正下方到左切点）
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
               startAngle: t1, endAngle: t2, clockwise: false)
    // 左侧：凹曲线回到顶点
    let m2 = CGPoint(x: (p2.x + apex.x) / 2, y: (p2.y + apex.y) / 2)
    ctx.addQuadCurve(to: apex, control: CGPoint(x: m2.x + concavity * (cx - p2.x), y: m2.y))
    ctx.closePath()
}

/// 波纹弧（采样点绘制，避免 arc 方向歧义）
func strokeArc(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, R: CGFloat,
               from: CGFloat, to: CGFloat, width: CGFloat, color: CGColor) {
    ctx.beginPath()
    let n = 64
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let a = from + (to - from) * t
        let p = CGPoint(x: cx + R * cos(a), y: cy + R * sin(a))
        if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
    }
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color)
    ctx.strokePath()
}

func roundRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat) {
    let p = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.beginPath()
    ctx.addPath(p)
}

// MARK: - 应用图标

func drawAppIcon(_ ctx: CGContext) {
    // 1) 渐变底（青蓝 → 深蓝，水的意向）
    let inset: CGFloat = 0.05
    let rect = CGRect(x: inset, y: inset, width: 1 - 2 * inset, height: 1 - 2 * inset)
    roundRect(ctx, rect, 0.22)

    let colors = [rgba(0.18, 0.74, 1.00),   // #2EBDFF
                  rgba(0.05, 0.36, 0.92)]   // #0D5CEB
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip()
    // 渐变方向：左上 → 右下（y 向下）
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 1, y: 1), options: [])
    ctx.restoreGState()

    // 2) 波纹（两道，半透明白）
    let cx: CGFloat = 0.5, cy: CGFloat = 0.50
    strokeArc(ctx, cx: cx, cy: cy, R: 0.395,
              from: 145 * .pi / 180, to: 35 * .pi / 180,
              width: 0.034, color: rgba(1, 1, 1, 0.28))
    strokeArc(ctx, cx: cx, cy: cy, R: 0.300,
              from: 145 * .pi / 180, to: 35 * .pi / 180,
              width: 0.034, color: rgba(1, 1, 1, 0.45))

    // 3) 水滴主体
    ctx.setFillColor(rgba(1, 1, 1, 1))
    addDroplet(ctx, cx: cx, cy: cy, r: 0.20, apexY: 0.13)
    ctx.fillPath()
}

// MARK: - 菜单栏三态图标

enum MenuState { case running, paused, stopped }

func drawMenuIcon(_ ctx: CGContext, _ state: MenuState) {
    let cx: CGFloat = 0.5, cy: CGFloat = 0.58, r: CGFloat = 0.30

    switch state {
    case .running:
        // 实心水滴 · 系统绿
        ctx.setFillColor(rgba(0.20, 0.78, 0.35))
        addDroplet(ctx, cx: cx, cy: cy, r: r, apexY: 0.06)
        ctx.fillPath()

    case .paused:
        // 实心水滴 · 琥珀橙 + 白色暂停双竖条
        ctx.setFillColor(rgba(1.00, 0.62, 0.04))
        addDroplet(ctx, cx: cx, cy: cy, r: r, apexY: 0.06)
        ctx.fillPath()

        ctx.setFillColor(rgba(1, 1, 1, 1))
        for x in [CGFloat(0.395), CGFloat(0.535)] {
            let bar = CGRect(x: x, y: 0.44, width: 0.070, height: 0.32)
            roundRect(ctx, bar, 0.03)
            ctx.fillPath()
        }

    case .stopped:
        // 空心水滴 · 中性灰描边（浅色/深色菜单栏均可辨）
        ctx.setFillColor(rgba(0.55, 0.55, 0.58, 0.18))
        addDroplet(ctx, cx: cx, cy: cy, r: r, apexY: 0.06)
        ctx.fillPath()
        ctx.setStrokeColor(rgba(0.42, 0.42, 0.45, 1))
        ctx.setLineWidth(0.115)
        addDroplet(ctx, cx: cx, cy: cy, r: r, apexY: 0.06)
        ctx.strokePath()
    }
}

// MARK: - 输出

func emit(_ name: String, _ px: Int, _ draw: (CGContext) -> Void) {
    guard let ctx = canvas(px) else { return }
    draw(ctx)
    guard let img = ctx.makeImage() else { return }
    writePNG(img, "\(outDir)/\(name)")
    print("  \(name)  (\(px)px)")
}

print("generating menu-bar icons:")
for (state, label) in [(MenuState.running, "running"),
                       (MenuState.paused, "paused"),
                       (MenuState.stopped, "stopped")] {
    emit("menubar_\(label).png", 18) { drawMenuIcon($0, state) }
    emit("menubar_\(label)@2x.png", 36) { drawMenuIcon($0, state) }
    emit("menubar_\(label)@3x.png", 54) { drawMenuIcon($0, state) }
}

print("generating app icon iconset:")
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    guard let ctx = canvas(px) else { continue }
    drawAppIcon(ctx)
    guard let img = ctx.makeImage() else { continue }
    writePNG(img, "\(iconset)/\(name)")
}
print("  AppIcon.iconset/ (\(sizes.count) sizes)")

// MARK: - 预览图（仅用于人工核对，不进 App 包）

func previewStrip() {
    let cell: CGFloat = 180, gap: CGFloat = 24, pad: CGFloat = 24
    let w = Int(pad * 2 + cell * 3 + gap * 2)
    let h = Int(pad * 2 + cell)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(rgba(0.94, 0.94, 0.96))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let states: [MenuState] = [.running, .paused, .stopped]
    for (i, s) in states.enumerated() {
        let x = pad + CGFloat(i) * (cell + gap)
        ctx.saveGState()
        ctx.translateBy(x: x, y: pad + cell)          // 左下角
        ctx.scaleBy(x: cell, y: -cell)                // y 向下
        drawMenuIcon(ctx, s)
        ctx.restoreGState()
    }
    guard let img = ctx.makeImage() else { return }
    writePNG(img, "\(outDir)/preview_menubar.png")
    print("  preview_menubar.png")
}

func previewAppIcon() {
    let px = 320
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(rgba(0.94, 0.94, 0.96))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: CGFloat(px), y: -CGFloat(px))
    drawAppIcon(ctx)
    guard let img = ctx.makeImage() else { return }
    writePNG(img, "\(outDir)/preview_appicon.png")
    print("  preview_appicon.png")
}

previewStrip()
previewAppIcon()
