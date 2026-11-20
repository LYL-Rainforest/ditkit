import SwiftUI
import AppKit
import DitKitCore

/// 报告存放位置配置：同目录 / 自定义目录 / 两者 / 都不选。
/// 两页（文件传输、重命名）共用；通过 binding 直接改 controller 里的 `ReportPlacement`。
struct ReportPlacementSection: View {
    @Binding var placement: ReportPlacement
    var isDisabled: Bool = false

    /// 同目录说明随页面不同：传输=目标目录根，重命名=原文件所在目录。
    var alongsideHint: String = "目标目录根"

    private var alongsideBinding: Binding<Bool> {
        Binding(
            get: { placement.writeAlongside },
            set: { placement.writeAlongside = $0 }
        )
    }
    private var customOnBinding: Binding<Bool> {
        Binding(
            get: { placement.useCustomDirectory },
            set: { on in
                placement.useCustomDirectory = on
                // 勾选但路径为空时填一个默认路径，避免「勾了却不生效」。
                if on, placement.customDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    placement.customDirectory = Self.defaultReportPath
                }
            }
        )
    }
    private var customPathBinding: Binding<String> {
        Binding(
            get: { placement.customDirectory },
            set: { placement.customDirectory = $0 }
        )
    }

    /// 勾选时的默认报告目录：文稿/DitKit 报告。
    private static var defaultReportPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("DitKit 报告").path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/DitKit 报告")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("报告存放位置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !placement.producesReports {
                    Text("· 未选，本次不生成报告")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("同目录", isOn: alongsideBinding)
                        .toggleStyle(.checkbox)
                        .disabled(isDisabled)
                    Text("写入每个\(alongsideHint)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("自定义目录", isOn: customOnBinding)
                        .toggleStyle(.checkbox)
                        .disabled(isDisabled)
                    HStack(spacing: 6) {
                        TextField("目录路径（可拖入文件夹）", text: customPathBinding)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isDisabled || !customOnBinding.wrappedValue)
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                guard !isDisabled, let p = providers.first else { return false }
                                _ = p.loadObject(ofClass: URL.self) { url, _ in
                                    guard let url, FileCopier.isDirectory(url) else { return }
                                    DispatchQueue.main.async {
                                        placement.customDirectory = url.path
                                        placement.useCustomDirectory = true
                                    }
                                }
                                return true
                            }
                        Button("选择…") { chooseDirectory() }
                            .disabled(isDisabled || !customOnBinding.wrappedValue)
                    }
                    Text("多份报告平铺此目录，文件名自动带来源标识，不会互相覆盖")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择报告存放目录（可先创建）"
        panel.prompt = "选择"
        if let current = placement.customURL, FileCopier.isDirectory(current) {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        placement.customDirectory = url.path
        placement.useCustomDirectory = true
    }
}
