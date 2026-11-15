// 生成 DMG 安装窗口的背景图（1320×800，对应 660×400 点窗口的 2 倍图）。
// Finder 会把它铺在图标视图底层，两个图标的位置由 layout.applescript 固定。
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let iconPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "macos/Resources/AppIcon.icns"
let width: CGFloat = 1320
let height: CGFloat = 800

func drawText(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let attributed = NSAttributedString(string: string, attributes: attrs)
    attributed.draw(at: NSPoint(x: (width - attributed.size().width) / 2, y: y))
}

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// 浅色渐变底
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.985, green: 0.990, blue: 1.000, alpha: 1),
    NSColor(calibratedRed: 0.860, green: 0.905, blue: 0.970, alpha: 1),
])
gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// 软件图标放大后作为半透明水印铺在中央，只做底纹，不与左侧真实 App 图标争夺注意力。
if let icon = NSImage(contentsOfFile: iconPath) {
    let side: CGFloat = 560
    icon.draw(
        in: NSRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side),
        from: .zero,
        operation: .sourceOver,
        // 细线条 / 透明底图标需要更实一些才能看清；彩色实心图标可用 0.12。
        fraction: 0.35
    )
} else {
    fputs("提示：未读到软件图标 \(iconPath)，背景图不含图标水印\n", stderr)
}

// 顶部细色条
NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.86, alpha: 1).setFill()
NSRect(x: 0, y: height - 14, width: width, height: 14).fill()

let ink = NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.27, alpha: 1)
let secondary = NSColor(calibratedRed: 0.34, green: 0.40, blue: 0.50, alpha: 1)
drawText("DitKit", y: 668, size: 68, weight: .bold, color: ink)
drawText("磁盘 SMART 健康 · 实时读写 IO · 顺序读写测速", y: 622, size: 26, weight: .medium, color: secondary)

// 两个图标之间的拖拽指示箭头（图标中心约在 y = 400）
let arrowColor = NSColor(calibratedRed: 0.26, green: 0.48, blue: 0.82, alpha: 0.75)
arrowColor.setStroke()
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 530, y: 400))
shaft.line(to: NSPoint(x: 770, y: 400))
shaft.lineWidth = 14
shaft.lineCapStyle = .round
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 724, y: 436))
head.line(to: NSPoint(x: 782, y: 400))
head.line(to: NSPoint(x: 724, y: 364))
head.lineWidth = 14
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

drawText("把左侧 DitKit 拖到右侧 Applications 完成安装", y: 126, size: 28, weight: .medium, color: secondary)
drawText("首次打开若提示「无法验证开发者」，请右键点击图标选择「打开」", y: 78, size: 20, weight: .regular, color: NSColor(calibratedRed: 0.50, green: 0.55, blue: 0.62, alpha: 1))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("生成背景 PNG 失败\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("背景图已生成：\(output)")
} catch {
    fputs("写入失败：\(error)\n", stderr)
    exit(1)
}
