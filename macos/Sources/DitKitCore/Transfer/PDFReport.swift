import Foundation
import CoreGraphics
import CoreText

/// 轻量 PDF 报告生成器：仅依赖 CoreGraphics/CoreText，无需外部库、可在无界面环境运行。
///
/// A4 版式：标题 + 元信息 + 汇总 + 明细表；明细表自动分页，每页重复表头，隔行浅灰底纹。
/// 列宽：`width == 0` 表示弹性列（平分剩余宽度），其余按固定宽度。
public enum PDFReport {

    public enum RowColor: Sendable {
        case normal   // 黑色
        case good     // 绿色（复制/更新/已重命名，且校验一致）
        case bad      // 红色（删除/失败/校验不一致）
        case muted    // 灰色（跳过/无需改动/待处理）
    }

    public struct Column: Sendable {
        public let name: String
        public let width: CGFloat
        public let monospace: Bool
        public init(name: String, width: CGFloat, monospace: Bool = false) {
            self.name = name
            self.width = width
            self.monospace = monospace
        }
    }

    public struct Row: Sendable {
        public let cells: [String]
        public let color: RowColor
        public init(_ cells: [String], color: RowColor = .normal) {
            self.cells = cells
            self.color = color
        }
    }

    // MARK: - 页面参数

    private static let pageWidth: CGFloat = 595.2    // A4
    private static let pageHeight: CGFloat = 841.8
    private static let margin: CGFloat = 42

    private static let titleFontName = "PingFangSC-Semibold"
    private static let bodyFontName = "PingFangSC-Regular"
    private static let headerFontName = "PingFangSC-Semibold"
    private static let monoFontName = "Menlo-Regular"

    // MARK: - 入口

    public static func write(
        title: String,
        meta: [String],
        summary: [String],
        columns: [Column],
        rows: [Row],
        to url: URL
    ) throws {
        let contentWidth = pageWidth - margin * 2

        // 解析弹性列。
        let fixedSum = columns.filter { $0.width > 0 }.reduce(CGFloat(0)) { $0 + $1.width }
        let flexCount = max(1, columns.filter { $0.width <= 0 }.count)
        let flexWidth = max(60, (contentWidth - fixedSum) / CGFloat(flexCount))
        let widths: [CGFloat] = columns.map { $0.width > 0 ? $0.width : flexWidth }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw NSError(domain: "PDFReport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF 上下文：\(url.path)"])
        }

        var y: CGFloat = 0

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // 翻转为自上而下的坐标体系（几何填充直接用 top-down 坐标；文字绘制在 draw() 内二次翻转）。
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)
            // 白色页面底色（避免透明背景在暗色查看器里显示为黑底）。
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            y = margin
        }

        func endPage() {
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        func tableHeader() {
            let cellFont = CTFontCreateWithName(headerFontName as CFString, 8.5, nil)
            let color = CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
            var headerHeight: CGFloat = 0
            var measured: [CGFloat] = []
            for (i, column) in columns.enumerated() {
                let h = measure(attr(column.name, font: cellFont, color: color), width: widths[i] - 6)
                measured.append(h)
                headerHeight = max(headerHeight, h)
            }
            headerHeight = max(headerHeight, 13) + 5
            // 表头底色。
            ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: margin, y: y, width: contentWidth, height: headerHeight))
            var x = margin
            for (i, column) in columns.enumerated() {
                _ = draw(attr(column.name, font: cellFont, color: color),
                         rect: CGRect(x: x + 3, y: y + 2, width: widths[i] - 6, height: headerHeight - 4),
                         ctx: ctx)
                x += widths[i]
            }
            y += headerHeight
        }

        beginPage()

        // 1) 标题
        let titleFont = CTFontCreateWithName(titleFontName as CFString, 15, nil)
        y += draw(attr(title, font: titleFont, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)),
                  rect: CGRect(x: margin, y: y, width: contentWidth, height: 22), ctx: ctx) + 8
        // 标题下分隔线
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: margin, y: y, width: contentWidth, height: 1))
        y += 8

        // 2) 元信息
        let metaFont = CTFontCreateWithName(bodyFontName as CFString, 9, nil)
        let metaColor = CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        for line in meta {
            y += draw(attr(line, font: metaFont, color: metaColor),
                      rect: CGRect(x: margin, y: y, width: contentWidth, height: 14), ctx: ctx) + 2
        }
        y += 6

        // 3) 汇总
        let summaryFont = CTFontCreateWithName(headerFontName as CFString, 9.5, nil)
        let summaryColor = CGColor(red: 0.05, green: 0.3, blue: 0.12, alpha: 1)
        for line in summary {
            y += draw(attr(line, font: summaryFont, color: summaryColor),
                      rect: CGRect(x: margin, y: y, width: contentWidth, height: 15), ctx: ctx) + 3
        }
        y += 8

        // 4) 明细表
        tableHeader()

        let bodyFont = CTFontCreateWithName(bodyFontName as CFString, 8.5, nil)
        let monoFont = CTFontCreateWithName(monoFontName as CFString, 6.8, nil)
        var zebra = false
        for row in rows {
            let rowColor = color(row.color)
            // 测量行高（各列取最大）。
            var rowHeight: CGFloat = 13
            for (i, cell) in row.cells.enumerated() where i < columns.count {
                let font = columns[i].monospace ? monoFont : bodyFont
                rowHeight = max(rowHeight, measure(attr(cell, font: font, color: rowColor), width: widths[i] - 6))
            }
            rowHeight += 5

            // 分页：放不下就翻页并重复表头。
            if y + rowHeight > pageHeight - margin {
                endPage()
                beginPage()
                tableHeader()
            }

            // 隔行底纹。
            if zebra {
                ctx.setFillColor(CGColor(red: 0.955, green: 0.955, blue: 0.96, alpha: 1))
                ctx.fill(CGRect(x: margin, y: y, width: contentWidth, height: rowHeight))
            }
            zebra.toggle()

            var x = margin
            for (i, cell) in row.cells.enumerated() where i < columns.count {
                let font = columns[i].monospace ? monoFont : bodyFont
                _ = draw(attr(cell, font: font, color: rowColor),
                         rect: CGRect(x: x + 3, y: y + 2, width: widths[i] - 6, height: rowHeight - 4),
                         ctx: ctx)
                x += widths[i]
            }
            y += rowHeight
        }

        if rows.isEmpty {
            let emptyFont = CTFontCreateWithName(bodyFontName as CFString, 9, nil)
            _ = draw(attr("（无记录）", font: emptyFont, color: color(.muted)),
                     rect: CGRect(x: margin, y: y + 4, width: contentWidth, height: 14), ctx: ctx)
        }

        endPage()
        ctx.closePDF()
    }

    // MARK: - 排版原语

    private static func attr(_ text: String, font: CTFont, color: CGColor) -> CFAttributedString {
        let dict: [NSAttributedString.Key: Any] = [
            // CoreText 属性键（kCTFontAttributeName 是 CFString，需桥接为 NSAttributedString.Key）。
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CFAttributedStringCreate(nil, text as CFString, dict as CFDictionary)!
    }

    /// 测量文本在给定宽度下的换行后高度。
    private static func measure(_ text: CFAttributedString, width: CGFloat) -> CGFloat {
        let length = CFAttributedStringGetLength(text)
        guard length > 0 else { return 11 }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return max(fit.height, 11)
    }

    /// 在 top-down 坐标的 rect 顶部绘制文本（内部处理坐标翻转），返回实际占用高度。
    private static func draw(_ text: CFAttributedString, rect: CGRect, ctx: CGContext) -> CGFloat {
        let length = CFAttributedStringGetLength(text)
        guard length > 0 else { return 11 }
        let height = measure(text, width: rect.width)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        ctx.saveGState()
        // 把 top-down 的 (x, y..y+h) 区域映射为文字自身坐标系的 (0, 0..h)。
        ctx.translateBy(x: rect.minX, y: rect.minY + height)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: length), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        return height
    }

    private static func color(_ kind: RowColor) -> CGColor {
        switch kind {
        case .normal: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .good: return CGColor(red: 0.05, green: 0.45, blue: 0.15, alpha: 1)
        case .bad: return CGColor(red: 0.72, green: 0.1, blue: 0.1, alpha: 1)
        case .muted: return CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        }
    }

    // MARK: - 格式工具

    /// 人类可读时间：yyyy-MM-dd HH:mm:ss。
    public static func readable(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// 字节数格式化（B/KB/MB/GB/TB，1024 进制）。
    public static func byteString(_ bytes: Int64) -> String {
        let units: [(String, Double)] = [("B", 1), ("KB", 1024), ("MB", 1024 * 1024),
                                         ("GB", 1024 * 1024 * 1024), ("TB", 1024 * 1024 * 1024 * 1024)]
        var chosen = units[0]
        for unit in units where Double(bytes) >= unit.1 { chosen = unit }
        let value = Double(bytes) / chosen.1
        return value >= 100 || chosen.0 == "B"
            ? "\(Int(value)) \(chosen.0)"
            : String(format: "%.1f %@", value, chosen.0)
    }
}
