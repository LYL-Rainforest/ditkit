import SwiftUI
import AppKit
import DitKitCore

@main
struct DitKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // MHL 报告查看器统一放「文件」菜单，不在主界面放按钮。
            CommandGroup(after: .newItem) {
                Button("查看 MHL 报告…") {
                    MHLViewerPresenter.shared.chooseAndOpen()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

/// SwiftPM 产出的可执行文件默认没有前台激活策略，直接运行不会弹出窗口。
/// 显式设为 regular 并激活，保证双击或 open 时窗口出现在最前面。
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 声明中文为首选语言：AppKit 会用中文本地化字符串构建标准菜单。
        // 打包时 Info.plist 也声明了 zh-Hans；这里是 SwiftPM 直跑时的兜底。
        UserDefaults.standard.register(defaults: ["AppleLanguages": ["zh_CN", "zh-Hans"]])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        localizeMainMenu()
        // SwiftUI 在启动阶段可能再补一次菜单项，下一轮 runloop 再兜底一次。
        Task { @MainActor in localizeMainMenu() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 幂等：窗口切换后菜单被重建时继续保证中文。
        localizeMainMenu()
    }

    /// 关闭 App 时一并结束它自己拉起的 ditkitd，避免残留后台进程和过期的 runtime.json。
    func applicationWillTerminate(_ notification: Notification) {
        DaemonController.shared.stop()
    }

    /// 把 AppKit / SwiftUI 生成的英文标准菜单项替换为中文。
    /// 自定义菜单项本身就是中文，这里只处理系统内置项；映射是幂等的。
    private func localizeMainMenu() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let menuTitles: [String: String] = [
            "File": "文件", "Edit": "编辑", "View": "视图", "Format": "格式",
            "Window": "窗口", "Help": "帮助", "Services": "服务",
            "Open Recent": "打开最近使用", "Find": "查找",
            "Spelling and Grammar": "拼写与语法", "Substitutions": "替换",
            "Transformations": "转换", "Speech": "语音",
        ]
        let itemTitles: [String: String] = [
            "About DitKit": "关于 DitKit",
            "Preferences…": "偏好设置…", "Preferences": "偏好设置", "Settings…": "设置…",
            "Hide DitKit": "隐藏 DitKit", "Hide Others": "隐藏其他", "Show All": "显示全部",
            "Quit DitKit": "退出 DitKit",
            "Close": "关闭", "Close Window": "关闭窗口", "New Window": "新建窗口",
            "Minimize": "最小化", "Zoom": "缩放", "Bring All to Front": "前置全部窗口",
            "Enter Full Screen": "进入全屏", "Exit Full Screen": "退出全屏",
            "Undo": "撤销", "Redo": "重做", "Cut": "剪切", "Copy": "拷贝",
            "Paste": "粘贴", "Paste and Match Style": "粘贴并匹配样式",
            "Delete": "删除", "Select All": "全选",
            "Open…": "打开…", "Save…": "存储…", "Print…": "打印…",
            "Clear Menu": "清除菜单", "Start Dictation…": "开始听写…",
            "Emoji & Symbols": "表情与符号", "DitKit Help": "DitKit 帮助",
        ]

        func rename(_ menu: NSMenu) {
            if let zh = menuTitles[menu.title] { menu.title = zh }
            for item in menu.items {
                if let zh = itemTitles[item.title] {
                    item.title = zh
                } else if let zh = menuTitles[item.title] {
                    item.title = zh
                }
                if let submenu = item.submenu { rename(submenu) }
            }
        }

        for item in mainMenu.items {
            if let zh = menuTitles[item.title] { item.title = zh }
            if let submenu = item.submenu { rename(submenu) }
        }
    }
}
