import Foundation
import Observation

/// 磁盘空间页的目录树状态。
///
/// 加载卷时只读顶层、秒级返回；随后在后台把顶层按占用大小排好、只保留前 4 项再显示。
/// 展开子目录时同样按大小排好（全部显示）。每层都是「统计完再排」，不会边算边跳。
/// 切换卷或停止时用 generation + 任务取消丢弃过期结果。
@MainActor
@Observable
public final class DiskTreeStore {
    /// 顶层保留的项目数。
    public static let topLimit = 4

    public var rootURL: URL?
    /// 父目录路径 → 已按占用大小降序排好的直接子项。
    public var nodes: [String: [DiskEntry]] = [:]
    public var status = "尚未选择卷"
    public var isReadingRoot = false
    public var isMeasuring = false
    /// 当前层统计进度：(已完成目录数, 目录总数)。
    public var progress: (done: Int, total: Int) = (0, 0)

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rankTask: Task<Void, Never>?

    public init() {}

    /// 切换卷：秒级读顶层，再按占用大小排好取前 4 显示。
    public func load(volume: VolumeInfo) async {
        stop()
        generation += 1
        let gen = generation
        rootURL = volume.url
        nodes.removeAll()
        status = "正在读取 \(volume.name) 的顶层…"
        isReadingRoot = true

        let root = volume.url
        let kids = await Task.detached(priority: .utility) {
            DiskSpaceScanner.children(of: root) { Task.isCancelled }
        }.value
        guard gen == generation else { return }
        isReadingRoot = false

        guard !kids.isEmpty else {
            status = "没有可读取的顶层项目"
            return
        }
        await rank(levelAt: root, items: kids, limit: Self.topLimit, gen: gen,
                   label: "正在统计顶层占用")
    }

    /// 展开目录：按占用大小排好它的所有子项（不截断）。
    public func expand(_ entry: DiskEntry) async {
        guard entry.isDirectory else { return }
        guard nodes[entry.path] == nil else { return }
        let gen = generation
        let path = entry.path
        let kids = await Task.detached(priority: .utility) {
            DiskSpaceScanner.children(of: URL(fileURLWithPath: path)) { Task.isCancelled }
        }.value
        guard gen == generation else { return }
        guard !kids.isEmpty else {
            nodes[path] = []
            return
        }
        await rank(levelAt: URL(fileURLWithPath: path), items: kids, limit: nil, gen: gen,
                   label: "正在统计「\(entry.name)」")
    }

    /// 停止当前统计（已排好的内容保留）。
    public func stop() {
        generation += 1
        rankTask?.cancel()
        rankTask = nil
        isMeasuring = false
    }

    // MARK: - 统计后排序

    private func rank(levelAt url: URL, items: [DiskEntry], limit: Int?, gen: Int,
                      label: String) async {
        isMeasuring = true
        progress = (0, items.filter { $0.isDirectory }.count)
        status = label + "…"

        let task = Task.detached(priority: .utility) { [weak self] in
            let ranked = DiskSpaceScanner.rankedChildren(in: url, limit: limit,
                isCancelled: { Task.isCancelled }
            ) { done, total in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.progress = (done, total)
                    self.status = "\(label)（\(done)/\(total)）…"
                }
            }
            await self?.apply(ranked, at: url.path, gen: gen)
        }
        rankTask = task
    }

    private func apply(_ entries: [DiskEntry], at path: String, gen: Int) {
        guard gen == generation else { return }
        nodes[path] = entries
        isMeasuring = false
        rankTask = nil
        if path == rootURL?.path {
            status = entries.isEmpty
                ? "没有可统计的顶层项目"
                : "已按占用大小列出前 \(entries.count) 项"
        } else {
            status = "已按占用大小排列该目录的子项"
        }
    }
}
