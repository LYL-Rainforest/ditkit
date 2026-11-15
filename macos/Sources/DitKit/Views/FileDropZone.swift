import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 拖拽项过滤

/// 放置区接受的条目类型。
enum DropFilter: Sendable {
    case filesAndFolders
    case directoriesOnly

    /// 返回通过过滤的 URL；不满足规则时为空数组（拖拽会被拒绝）。
    func accepted(_ urls: [URL]) -> [URL] {
        switch self {
        case .filesAndFolders:
            return urls
        case .directoriesOnly:
            return urls.filter { Self.isDirectory($0) }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) else { return false }
        return flag.boolValue
    }
}

/// 拖拽粘贴板解析。抽成独立值以便用真实 NSPasteboard 验证，而不依赖 UI 事件。
enum DropPasteboard {
    /// 依次尝试三种读取方式，兼容 Finder、旧版应用与纯 URL 粘贴板。
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [NSURL], !objects.isEmpty {
            return objects.map { $0 as URL }
        }

        let legacy = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacy) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }

        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let raw = item.string(forType: .fileURL),
                  let url = URL(string: raw), url.isFileURL else { return nil }
            return url
        }
    }
}

// MARK: - AppKit 原生拖拽接收层

/// 用 `NSView` + `NSDraggingDestination` 接收 Finder 拖拽。
///
/// 本项目早期使用 SwiftUI `.onDrop` / `DropDelegate`，实测拖入无响应，因此改为
/// AppKit 原生注册拖拽类型。该视图同时接管点击（由 `mouseDown` 触发选择面板），
/// 这样覆盖在 SwiftUI 内容上方时，点击与拖拽都能生效。
@MainActor
final class FileDropNSView: NSView {
    var filter: DropFilter = .filesAndFolders
    var isDisabled = false
    var onHighlight: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 现代 Finder 提供 public.file-url；旧应用可能只提供 NSFilenamesPboardType。
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 非前台窗口也能一次点击生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 禁用时返回 nil：点击穿透给下层 SwiftUI 控件，同时也拒绝拖拽。
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDisabled ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabled else { return }
        onTap?()
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptable(sender) else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptable(sender) else {
            onHighlight?(false)
            return []
        }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isDisabled
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        guard !isDisabled else { return false }
        let urls = filter.accepted(extractURLs(sender))
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    // MARK: - 内部

    private func isAcceptable(_ sender: NSDraggingInfo) -> Bool {
        guard !isDisabled else { return false }
        return !filter.accepted(extractURLs(sender)).isEmpty
    }

    private func extractURLs(_ sender: NSDraggingInfo) -> [URL] {
        DropPasteboard.fileURLs(sender.draggingPasteboard)
    }
}

/// 透明接收层，可覆盖在任意 SwiftUI 视图上；外观由调用方自己控制。
struct FileDropReceiver: NSViewRepresentable {
    let filter: DropFilter
    let isDisabled: Bool
    let onHighlight: (Bool) -> Void
    let onTap: () -> Void
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropNSView {
        let view = FileDropNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FileDropNSView, context: Context) {
        configure(nsView)
    }

    @MainActor
    private func configure(_ view: FileDropNSView) {
        view.filter = filter
        view.isDisabled = isDisabled
        view.onHighlight = onHighlight
        view.onTap = onTap
        view.onDrop = onDrop
    }
}

// MARK: - 带外观的大放置区

/// 虚线框放置区：点击弹出选择面板，拖入自动追加；拖入时边框与底色高亮。
struct FileDropZone<Label: View>: View {
    private let filter: DropFilter
    private let isDisabled: Bool
    private let minHeight: CGFloat
    private let cornerRadius: CGFloat
    private let onTap: () -> Void
    private let onDrop: ([URL]) -> Void
    private let label: () -> Label

    @State private var isTargeted = false

    init(
        filter: DropFilter = .filesAndFolders,
        isDisabled: Bool = false,
        minHeight: CGFloat = 78,
        cornerRadius: CGFloat = 12,
        onTap: @escaping () -> Void,
        onDrop: @escaping ([URL]) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.filter = filter
        self.isDisabled = isDisabled
        self.minHeight = minHeight
        self.cornerRadius = cornerRadius
        self.onTap = onTap
        self.onDrop = onDrop
        self.label = label
    }

    var body: some View {
        label()
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(
                isTargeted ? Color.accentColor.opacity(0.16) : Color.accentColor.opacity(0.06),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isTargeted ? Color.accentColor : Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 4])
                    )
            )
            .overlay(
                FileDropReceiver(
                    filter: filter,
                    isDisabled: isDisabled,
                    onHighlight: { highlighted in isTargeted = highlighted },
                    onTap: onTap,
                    onDrop: onDrop
                )
            )
            .opacity(isDisabled ? 0.55 : 1)
    }
}
