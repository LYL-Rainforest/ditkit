import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DitKitCore

/// 负责弹出独立窗口并持有窗口控制器，避免窗口被立即释放。
@MainActor
final class MHLViewerPresenter {
    static let shared = MHLViewerPresenter()

    private var windowControllers: [NSWindowController] = []

    /// 弹选择面板让用户挑任意 `.mhl` 文件（含历史报告），然后打开查看器。
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "查看"
        panel.message = "选择 DitKit 生成的 ASC MHL 报告（.mhl）"
        panel.allowedContentTypes = [UTType(filenameExtension: "mhl") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// 直接打开指定的 MHL 文件（也供结果区调用）。
    func open(_ url: URL) {
        // 清掉已关闭窗口的控制器，避免长期持有 SwiftUI 视图。
        windowControllers.removeAll { $0.window?.isVisible == false }

        do {
            let document = try MHLReader.read(url)
            let state = MHLViewerState(document: document)
            let hosting = NSHostingController(rootView: MHLViewerView(state: state))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1340, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "MHL 报告 · \(url.lastPathComponent)"
            window.contentViewController = hosting
            window.setFrameAutosaveName("DitKitMHLViewer")
            window.center()
            let controller = NSWindowController(window: window)
            windowControllers.append(controller)
            controller.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法打开 MHL 报告"
            alert.informativeText = "\(url.lastPathComponent)\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
