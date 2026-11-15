import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DitKitCore

/// 实时 IO 折线图：蓝色=读取、红色=写入。
/// 横轴固定为最近 10 分钟，刻度不随采样点数量变化；新数据从右端进入，历史向左滚动。
struct IOChart: View {
    let samples: [IOSample]
    let windowSeconds: Int

    private let readColor = Color(red: 0.36, green: 0.72, blue: 1.0)
    private let writeColor = Color(red: 1.0, green: 0.38, blue: 0.42)
    private let gridColor = Color.white.opacity(0.10)
    private let axisColor = Color.white.opacity(0.55)

    private var duration: TimeInterval { Double(windowSeconds) }

    var body: some View {
        Canvas { context, size in
            draw(context: &context, size: size)
        }
        .background(Color(red: 0.07, green: 0.11, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let inset = EdgeInsets(top: 20, leading: 78, bottom: 24, trailing: 12)
        let plot = CGRect(
            x: inset.leading,
            y: inset.top,
            width: max(1, size.width - inset.leading - inset.trailing),
            height: max(1, size.height - inset.top - inset.bottom)
        )
        let end = samples.last?.timestamp ?? Date()
        let start = end.addingTimeInterval(-duration)
        let visible = samples.filter { $0.timestamp >= start }
        let ceiling = ChartScale.ceiling(visible.reduce(0) {
            max($0, max($1.readBytesPerSecond, $1.writeBytesPerSecond))
        })

        // 水平网格与纵轴刻度
        for i in 0...5 {
            let ratio = Double(i) / 5
            let y = plot.maxY - CGFloat(ratio) * plot.height
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
            let label = Text(IOFormat.axis(ceiling * ratio, ceiling: ceiling))
                .font(.system(size: 10))
                .foregroundColor(axisColor)
            context.draw(label, at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }

        // 垂直网格与固定时间刻度：每 2 分钟一条线，不随采样点数量变化
        for tick in IOGrid.verticalLines(windowSeconds: windowSeconds) {
            let x = plot.minX + CGFloat(tick.ratio) * plot.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
            let label = Text(IOGrid.timeLabel(minutesAgo: tick.minutesAgo))
                .font(.system(size: 10))
                .foregroundColor(axisColor)
            context.draw(label, at: CGPoint(x: x, y: plot.maxY + 12),
                         anchor: tick.ratio == 0 ? .leading : (tick.ratio == 1 ? .trailing : .center))
        }

        // 图例按曲线配色分色显示
        context.draw(
            Text("— 读取").font(.system(size: 10)).foregroundColor(readColor),
            at: CGPoint(x: plot.minX, y: 10), anchor: .topLeading
        )
        context.draw(
            Text("— 写入").font(.system(size: 10)).foregroundColor(writeColor),
            at: CGPoint(x: plot.minX + 54, y: 10), anchor: .topLeading
        )

        drawSeries(visible, keyPath: \.readBytesPerSecond, color: readColor,
                   context: &context, plot: plot, start: start, ceiling: ceiling)
        drawSeries(visible, keyPath: \.writeBytesPerSecond, color: writeColor,
                   context: &context, plot: plot, start: start, ceiling: ceiling)
    }

    private func drawSeries(
        _ visible: [IOSample],
        keyPath: KeyPath<IOSample, Double>,
        color: Color,
        context: inout GraphicsContext,
        plot: CGRect,
        start: Date,
        ceiling: Double
    ) {
        guard visible.count > 1 else { return }
        var path = Path()
        for (index, sample) in visible.enumerated() {
            let x = plot.minX + CGFloat(sample.timestamp.timeIntervalSince(start) / duration) * plot.width
            let raw = sample[keyPath: keyPath]
            let y = plot.maxY - CGFloat(min(raw / ceiling, 1)) * plot.height
            let point = CGPoint(x: min(max(x, plot.minX), plot.maxX), y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }
}

private enum ChartScale {
    /// 向上取整到 1.5 / 2 / 3 / 5 / 8 / 10 × 10ⁿ，避免刻度出现 7.3 GB/秒 这种怪数字。
    static func ceiling(_ peak: Double) -> Double {
        let target = max(peak * 1.2, 1_000_000)
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let step: Double
        switch normalized {
        case ..<1.5: step = 1.5
        case ..<2: step = 2
        case ..<3: step = 3
        case ..<5: step = 5
        case ..<8: step = 8
        default: step = 10
        }
        return step * magnitude
    }

}

/// 导出用包装视图：固定尺寸、固定深色外观，保证 PNG 在任何系统外观下一致。
struct IOChartExportView: View {
    let samples: [IOSample]
    let windowSeconds: Int
    let interval: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DitKit · 实时磁盘 IO 图表")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
            Text("蓝色＝读取 · 红色＝写入 · 采样间隔 \(Int((interval * 1000).rounded())) 毫秒 · 窗口 \(windowSeconds / 60) 分钟 · 生成时间 \(Date().formatted(date: .numeric, time: .standard))")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            IOChart(samples: samples, windowSeconds: windowSeconds)
                .frame(height: 340)
        }
        .padding(20)
        .frame(width: 1100, height: 420)
        .background(Color(red: 0.10, green: 0.13, blue: 0.12))
    }
}

@MainActor
enum IOChartExporter {
    static func pngData(samples: [IOSample], windowSeconds: Int, interval: TimeInterval) -> Data? {
        let view = IOChartExportView(samples: samples, windowSeconds: windowSeconds, interval: interval)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func save(samples: [IOSample], windowSeconds: Int, interval: TimeInterval) -> String {
        guard let data = pngData(samples: samples, windowSeconds: windowSeconds, interval: interval) else {
            return "图表导出失败"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DitKit-实时IO图表.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        do {
            try data.write(to: url, options: .atomic)
            return "已导出 \(url.lastPathComponent)"
        } catch {
            return "导出失败：\(error.localizedDescription)"
        }
    }
}
