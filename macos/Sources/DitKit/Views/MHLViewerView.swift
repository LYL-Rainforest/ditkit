import SwiftUI
import AppKit
import Observation
import DitKitCore

/// 取路径中的文件名部分（不含目录），供搜索匹配与表格显示共用。
private func mhlFileName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// 取路径中的目录部分；纯文件名返回空串。
private func mhlDirectory(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    return (dir.isEmpty || dir == ".") ? "" : dir
}

/// 操作筛选条件；`unlabeled` 对应没有明细段的旧 MHL / 第三方清单。
enum ActionFilter: Hashable, Identifiable {
    case all
    case named(String)
    case unlabeled

    var id: String {
        switch self {
        case .all: return "__all__"
        case .named(let name): return "named:\(name)"
        case .unlabeled: return "__unlabeled__"
        }
    }
}

/// 下拉选项，label 后面由工具栏拼上条数。
struct ActionOption: Identifiable {
    let filter: ActionFilter
    let label: String
    let count: Int
    var id: String { filter.id }
}

/// 状态筛选条件；与操作筛选同构。
enum StatusFilter: Hashable, Identifiable {
    case all
    case status(MHLVerifier.Status)

    var id: String {
        switch self {
        case .all: return "__all_status__"
        case .status(let status): return "status:\(status.rawValue)"
        }
    }
}

struct StatusOption: Identifiable {
    let filter: StatusFilter
    let label: String
    let count: Int
    var id: String { filter.id }
}

extension MHLVerifier.Status {
    /// 状态下拉的固定展示顺序（与表格「状态」列一致）。
    static let displayOrder: [MHLVerifier.Status] = [
        .unchecked, .matched, .mismatch, .missing, .failed, .unsupported, .notApplicable
    ]

    var displayName: String {
        switch self {
        case .unchecked: return "未校验"
        case .matched: return "一致"
        case .mismatch: return "不一致"
        case .missing: return "缺失"
        case .unsupported: return "不支持"
        case .failed: return "出错"
        case .notApplicable: return "不校验"
        }
    }
}

/// MHL 查看器窗口的界面状态。
@MainActor
@Observable
final class MHLViewerState {
    let document: MHLDocument
    var rows: [MHLVerifier.Result]
    var searchText = ""
    /// 当前操作筛选；默认「全部操作」。
    var selectedAction: ActionFilter = .all
    /// 当前状态筛选；默认「全部状态」。校验完成后自动重置，避免结果随状态变化消失。
    var selectedStatus: StatusFilter = .all
    var isVerifying = false
    var hasVerified = false
    var errorMessage: String?
    var isPaused = false
    var wasStopped = false
    var verifyDone = 0
    var verifyTotal = 0

    @ObservationIgnored private var control = RunControl()

    init(document: MHLDocument) {
        self.document = document
        self.rows = MHLVerifier.initialRows(document)
    }

    /// 下拉选项：按当前清单实际出现的操作动态生成，已知操作按固定顺序、未知操作按名称排序。
    var actionOptions: [ActionOption] {
        var counts: [String: Int] = [:]
        var unlabeled = 0
        for row in rows {
            if let action = row.action, !action.isEmpty {
                counts[action, default: 0] += 1
            } else {
                unlabeled += 1
            }
        }
        var options: [ActionOption] = [
            .init(filter: .all, label: "全部操作", count: rows.count)
        ]
        let preferred = ["复制", "更新", "跳过", "删除", "失败",
                         "已重命名", "无需改动", "待处理", "已停止"]
        var used = Set<String>()
        for name in preferred where counts[name] != nil {
            options.append(.init(filter: .named(name), label: name, count: counts[name] ?? 0))
            used.insert(name)
        }
        for name in counts.keys.filter({ !used.contains($0) }).sorted() {
            options.append(.init(filter: .named(name), label: name, count: counts[name] ?? 0))
        }
        if unlabeled > 0 {
            options.append(.init(filter: .unlabeled, label: "未标注", count: unlabeled))
        }
        return options
    }

    /// 状态下拉选项：条数按「操作 + 搜索」之后的集合统计，因此三个筛选联动、不会选到必然为空的组合。
    var statusOptions: [StatusOption] {
        let scope = actionSearchIndexes.map { rows[$0] }
        var counts: [MHLVerifier.Status: Int] = [:]
        for row in scope { counts[row.status, default: 0] += 1 }
        var options: [StatusOption] = [
            .init(filter: .all, label: "全部状态", count: scope.count)
        ]
        for status in MHLVerifier.Status.displayOrder where counts[status] != nil {
            options.append(.init(filter: .status(status), label: status.displayName,
                                 count: counts[status] ?? 0))
        }
        // 兜底：切换操作/搜索后若当前选中的状态已无匹配项，仍保留该项，避免 Picker 空选。
        if case .status(let status) = selectedStatus, counts[status] == nil {
            options.append(.init(filter: .status(status), label: status.displayName, count: 0))
        }
        return options
    }

    /// 切换操作或搜索词后，清掉已经没有匹配行的状态选中项。
    func pruneStatusSelection() {
        guard case .status(let status) = selectedStatus else { return }
        let stillAvailable = statusOptions.contains {
            $0.filter == .status(status) && $0.count > 0
        }
        if !stillAvailable { selectedStatus = .all }
    }

    /// 「操作 + 搜索」叠加后的索引（不含状态条件），供状态条数统计复用。
    private var actionSearchIndexes: [Int] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.indices.filter { index in
            let row = rows[index]
            guard matchesAction(row) else { return false }
            return q.isEmpty || matchesSearch(row, q)
        }
    }

    /// 操作、状态、文本搜索三者 AND 叠加后的行索引；校验时用它做快照，保证按索引合并回全量 rows。
    private var visibleIndexes: [Int] {
        let base = actionSearchIndexes
        guard case .status(let status) = selectedStatus else { return base }
        return base.filter { rows[$0].status == status }
    }

    private func matchesAction(_ row: MHLVerifier.Result) -> Bool {
        switch selectedAction {
        case .all: return true
        case .named(let name): return row.action == name
        case .unlabeled: return (row.action ?? "").isEmpty
        }
    }

    /// 模糊匹配（忽略大小写）：现文件名、原文件名、完整相对路径、哈希、操作名。
    /// 现/原文件名都取 basename，单独列出来与完整路径区分，便于按纯文件名查找。
    private func matchesSearch(_ row: MHLVerifier.Result, _ q: String) -> Bool {
        let currentName = mhlFileName(row.entry.path).lowercased()
        let previousName = row.entry.previousPath.map { mhlFileName($0).lowercased() } ?? ""
        return currentName.contains(q)
            || row.entry.path.lowercased().contains(q)
            || row.entry.hashValue.lowercased().contains(q)
            || (!previousName.isEmpty && previousName.contains(q))
            || (row.action?.lowercased().contains(q) ?? false)
    }

    var filteredRows: [MHLVerifier.Result] { visibleIndexes.map { rows[$0] } }

    /// 任一筛选生效时，汇总文案加「当前筛选 ·」前缀。
    private var isFiltered: Bool {
        selectedAction != .all || selectedStatus != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 汇总统计跟随当前筛选，与「校验当前」保持一致。
    var summary: String {
        let scope = filteredRows
        let prefix = isFiltered ? "当前筛选 · " : ""
        let matched = scope.filter { $0.status == .matched }.count
        let mismatch = scope.filter { $0.status == .mismatch }.count
        let missing = scope.filter { $0.status == .missing }.count
        let bad = scope.filter { $0.status == .failed || $0.status == .unsupported }.count
        let nonVerifiable = scope.filter { $0.status == .notApplicable }.count
        let unchecked = scope.filter { $0.status == .unchecked }.count
        if !hasVerified { return prefix + "共 \(scope.count) 条 · 尚未校验" }
        var tail = "一致 \(matched) · 不一致 \(mismatch) · 缺失 \(missing) · 异常 \(bad) · 共 \(scope.count) 条"
        if nonVerifiable > 0 { tail = "不校验 \(nonVerifiable) · " + tail }
        if unchecked > 0 { tail += " · 未校验 \(unchecked)" }
        return wasStopped ? "已停止（部分校验） · \(prefix)\(tail)" : prefix + tail
    }

    /// 校验「操作 + 状态 + 搜索」筛选后可见的行；结果按索引合并回全量 rows，筛选外的行不受影响。
    /// 校验结束（含停止）后把状态筛选重置为「全部状态」，避免筛「未校验」时结果瞬间消失。
    /// 逐条检查暂停/停止，停止后未校验条目保持「未校验」。
    func verify() async {
        guard !isVerifying else { return }
        let indexes = visibleIndexes
        guard !indexes.isEmpty else { return }
        control = RunControl()
        isVerifying = true
        isPaused = false
        wasStopped = false
        verifyDone = 0
        verifyTotal = indexes.count
        defer {
            isVerifying = false
            isPaused = false
            selectedStatus = .all
        }
        let onProgress: @MainActor (Int, Int) -> Void = { [weak self] done, total in
            guard let self else { return }
            self.verifyDone = done
            self.verifyTotal = total
        }
        let selected = indexes.map { rows[$0] }
        let outcome = await MHLVerifier.verifySelected(
            selected, in: document, control: control, onProgress: onProgress
        )
        for (offset, index) in indexes.enumerated() where offset < outcome.rows.count {
            rows[index] = outcome.rows[offset]
        }
        wasStopped = outcome.stopped
        hasVerified = true
    }

    func pauseOrResume() {
        guard isVerifying else { return }
        if isPaused {
            control.resume()
            isPaused = false
        } else {
            control.pause()
            isPaused = true
        }
    }

    func stop() {
        guard isVerifying else { return }
        control.stop()
        isPaused = false
    }

    func copyHash(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }
}

/// MHL 报告查看器：完整清单 + 一键校验，展示在独立窗口里。
struct MHLViewerView: View {
    @State var state: MHLViewerState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            tableHeader
            tableBody
        }
        .frame(minWidth: 1320, minHeight: 440)
        .onChange(of: state.selectedAction) { _, _ in state.pruneStatusSelection() }
        .onChange(of: state.searchText) { _, _ in state.pruneStatusSelection() }
    }

    // MARK: - 头部信息

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.document.url.lastPathComponent)
                .font(.system(size: 15, weight: .medium))
                .textSelection(.enabled)
            Text(state.document.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                info("标准版本", state.document.version.isEmpty ? "—" : "ASC MHL v\(state.document.version)")
                info("流程类型", state.document.process.isEmpty ? "—" : state.document.process)
                info("条目数", "\(state.rows.count)")
                info("创建时间", state.document.creationDate.isEmpty ? "—" : state.document.creationDate)
                info("主机名", state.document.hostname.isEmpty ? "—" : state.document.hostname)
                info("生成工具", state.document.toolName.isEmpty ? "—" : state.document.toolName + (state.document.toolVersion.isEmpty ? "" : " \(state.document.toolVersion)"))
            }
            .padding(.top, 4)
            // 完整明细段里的元信息与汇总：与 PDF 报告同源。
            if let detail = state.document.detail {
                VStack(alignment: .leading, spacing: 3) {
                    if !detail.meta.isEmpty {
                        Text(detail.meta.joined(separator: "  ·  "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    ForEach(detail.summary, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func info(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).lineLimit(1)
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("现文件名 / 原文件名 / 路径 / 哈希", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 268)
            HStack(spacing: 4) {
                Text("操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.selectedAction) {
                    ForEach(state.actionOptions) { option in
                        Text("\(option.label) \(option.count)").tag(option.filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 148)
                .disabled(state.isVerifying)
            }
            HStack(spacing: 4) {
                Text("状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.selectedStatus) {
                    ForEach(state.statusOptions) { option in
                        Text("\(option.label) \(option.count)").tag(option.filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 148)
                .disabled(state.isVerifying)
            }
            Text("\(state.filteredRows.count)/\(state.rows.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if state.isVerifying {
                ProgressView(value: Double(state.verifyDone),
                             total: Double(max(1, state.verifyTotal)))
                    .frame(width: 84)
                Text(state.isPaused ? "已暂停 \(state.verifyDone)/\(state.verifyTotal)"
                                   : "校验中 \(state.verifyDone)/\(state.verifyTotal)")
                    .font(.caption2)
                    .foregroundStyle(state.isPaused ? Color.orange : Color.secondary)
                Button(state.isPaused ? "继续" : "暂停") { state.pauseOrResume() }
                Button("停止", role: .destructive) { state.stop() }
            }
            Text(state.summary)
                .font(.caption)
                .foregroundStyle(summaryColor)
                .lineLimit(1)
            Button("在 Finder 中显示") { state.revealInFinder() }
            Button(state.filteredRows.count == state.rows.count ? "校验全部" : "校验当前") {
                Task { await state.verify() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(state.isVerifying || state.filteredRows.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summaryColor: Color {
        guard state.hasVerified else { return .secondary }
        let bad = state.filteredRows.contains { $0.status == .mismatch || $0.status == .missing || $0.status == .failed }
        return bad ? .red : .green
    }

    // MARK: - 表格

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("操作").frame(width: 62, alignment: .leading)
            Text("状态").frame(width: 62, alignment: .leading)
            Text("现文件名").frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            Text("原文件名").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 72, alignment: .trailing)
            Text("算法").frame(width: 52, alignment: .leading)
            Text("哈希值").frame(width: 210, alignment: .leading)
            Text("").frame(width: 40)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.07))
    }

    private var tableBody: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(state.filteredRows) { row in
                    rowView(row)
                }
                if state.filteredRows.isEmpty {
                    Text(state.rows.isEmpty ? "清单中没有哈希条目" : "当前操作 / 状态 / 搜索条件下没有匹配的条目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: MHLVerifier.Result) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.action ?? "—")
                .font(.caption2.weight(.medium))
                .foregroundStyle(actionColor(row.action))
                .frame(width: 62, alignment: .leading)
            Text(row.status.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(statusColor(row.status))
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(mhlFileName(row.entry.path))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                if !mhlDirectory(row.entry.path).isEmpty {
                    Text("目录：\(mhlDirectory(row.entry.path))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            .help(row.entry.path)
            Text(row.entry.previousPath.map { mhlFileName($0) } ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.entry.previousPath == nil ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                .help(row.entry.previousPath ?? "无原文件名")
            Text(sizeText(row.entry.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(row.entry.algorithm.isEmpty ? "—" : row.entry.algorithm)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.hashValue.isEmpty ? "—" : row.entry.hashValue)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                if let actual = row.actualHash, row.status == .mismatch {
                    Text("实际：\(actual)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .leading)
            Button {
                state.copyHash(row.entry.hashValue)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .frame(width: 40)
            .disabled(row.entry.hashValue.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusColor(_ status: MHLVerifier.Status) -> Color {
        switch status {
        case .unchecked, .unsupported, .notApplicable: return .secondary
        case .matched: return .green
        case .mismatch, .failed: return .red
        case .missing: return .orange
        }
    }

    /// 与 PDF 明细表一致的操作配色：复制/更新/已重命名绿、跳过灰、删除红。
    private func actionColor(_ action: String?) -> Color {
        guard let action else { return .secondary }
        switch action {
        case "复制", "更新", "已重命名": return .green
        case "跳过", "无需改动", "待处理": return .secondary
        case "删除", "失败": return .red
        default: return .secondary
        }
    }

    private func sizeText(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return PDFReport.byteString(size)
    }
}
