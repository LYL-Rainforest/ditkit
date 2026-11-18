import SwiftUI
import AppKit
import DitKitCore

/// 主窗口容器：五个切换按钮放在窗口最顶部的标题栏，标题文字放在按钮下方的内容区第一行。
/// SMART 健康、磁盘空间、磁盘性能、文件传输、EXIF 重命名五个页面始终共存于 ZStack（用透明度切换），
/// 这样切换标签不会销毁视图，IO 采样器、历史曲线、测速状态与重命名预览得以保留。
struct ContentView: View {
    private enum Tab: Hashable {
        case smart
        case diskSpace
        case performance
        case transfer
        case rename
    }

    @State private var state = AppState()

    // 仅用于联调：直接运行二进制时传 --io / --speedtest 可以指定启动页。
    private static var launchTab: Tab {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--io") || args.contains("--speedtest") || args.contains("--speedtest-run") { return .performance }
        if args.contains("--diskspace") { return .diskSpace }
        if args.contains("--transfer") { return .transfer }
        if args.contains("--rename") { return .rename }
        return .smart
    }
    @State private var selection: Tab = ContentView.launchTab

    private var pageTitle: String {
        switch selection {
        case .smart: return "DitKit · 磁盘 SMART 健康"
        case .performance: return "DitKit · 磁盘性能"
        case .diskSpace: return "DitKit · 磁盘空间"
        case .transfer: return "DitKit · 文件传输"
        case .rename: return "DitKit · 素材 EXIF 重命名"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题位于切换按钮下方
            Text(pageTitle)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ZStack {
                SMARTView(state: state)
                    .opacity(selection == .smart ? 1 : 0)
                    .allowsHitTesting(selection == .smart)
                DiskSpaceView()
                    .opacity(selection == .diskSpace ? 1 : 0)
                    .allowsHitTesting(selection == .diskSpace)
                PerformanceView()
                    .opacity(selection == .performance ? 1 : 0)
                    .allowsHitTesting(selection == .performance)
                TransferView()
                    .opacity(selection == .transfer ? 1 : 0)
                    .allowsHitTesting(selection == .transfer)
                RenameView()
                    .opacity(selection == .rename ? 1 : 0)
                    .allowsHitTesting(selection == .rename)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 标题栏不再显示长窗口标题，只容纳切换按钮与工具栏操作。
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $selection) {
                    Text("SMART 健康").tag(Tab.smart)
                    Text("磁盘空间").tag(Tab.diskSpace)
                    Text("磁盘性能").tag(Tab.performance)
                    Text("文件传输").tag(Tab.transfer)
                    Text("重命名").tag(Tab.rename)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 560)
            }
            if selection == .smart {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await state.connect() }
                    } label: {
                        Label("重新连接并刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        // macOS 的窗口状态恢复会让启动页不确定，这里显式锁定为启动参数指定的标签。
        .onAppear { selection = Self.launchTab }
        .task { await state.connect() }
        .frame(minWidth: 1000, minHeight: 680)
    }
}
