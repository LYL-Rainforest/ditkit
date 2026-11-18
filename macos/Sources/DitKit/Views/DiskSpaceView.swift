import SwiftUI
import AppKit
import DitKitCore

/// 磁盘空间页：所有已挂载卷的容量概览，选中卷后按需展开目录树。
struct DiskSpaceView: View {
    @State private var volumes: [VolumeInfo] = []
    @State private var selectedID: String?
    @State private var tree = DiskTreeStore()

    private var selected: VolumeInfo? { volumes.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            volumeList
            treePane
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await refresh() }
        .onChange(of: selectedID) { _, newID in
            guard let volume = volumes.first(where: { $0.id == newID }) else { return }
            Task { await tree.load(volume: volume) }
        }
        .onDisappear { tree.stop() }
    }

    // MARK: 顶部说明

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("磁盘空间").font(.headline)
                Text("只读枚举所有已挂载卷；目录按占用大小降序排列，顶层显示最大的 4 项，展开子目录可继续钻取；右键可在 Finder 中显示或复制路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("刷新卷列表", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    // MARK: 卷列表

    private var volumeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已挂载卷（\(volumes.count)）")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(volumes) { volume in
                        Button {
                            selectedID = volume.id
                        } label: {
                            volumeRow(volume)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: volume.isRoot ? "internaldrive" :
                      (volume.isRemovable ? "externaldrive" : "opticaldisc"))
                    .foregroundStyle(volume.id == selectedID ? Color.accentColor : .secondary)
                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(volume.id == selectedID ? Color.accentColor : .primary)
                if volume.isRoot { Text("启动卷").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text("已用 \(IOFormat.capacity(volume.usedBytes)) · 剩余 \(IOFormat.capacity(volume.freeBytes)) · 总量 \(IOFormat.capacity(volume.totalBytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CapacityBar(ratio: volume.usedRatio)
                .frame(height: 8)
            HStack(spacing: 10) {
                Text(volume.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !volume.fileSystemType.isEmpty {
                    Text(volume.fileSystemType).font(.caption2).foregroundStyle(.secondary)
                }
                Text(volume.isLocal ? "本地" : "网络").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            volume.id == selectedID
                ? Color.accentColor.opacity(0.10)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: 目录树

    private var treePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("目录占用").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let selected { Text("· \(selected.name)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if tree.isMeasuring {
                    ProgressView().controlSize(.small)
                    Button("停止统计") { tree.stop() }
                        .controlSize(.small)
                }
            }
            Text(tree.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if tree.isMeasuring && tree.progress.total > 0 {
                Text("已统计 \(tree.progress.done)/\(tree.progress.total) 个目录，完成后按大小排列")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if let root = tree.rootURL, let roots = tree.nodes[root.path] {
                        ForEach(roots) { entry in
                            DiskTreeNodeView(entry: entry, tree: tree)
                        }
                    } else if tree.isReadingRoot {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取顶层…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: 数据

    private func refresh() async {
        let found = await Task.detached(priority: .utility) {
            DiskSpaceScanner.volumes()
        }.value
        volumes = found
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            selectedID = found.first?.id
        }
        if let volume = volumes.first(where: { $0.id == selectedID }) {
            await tree.load(volume: volume)
        }
    }
}

/// 树中一个节点：目录可展开，右键提供 Finder 定位与复制路径。
private struct DiskTreeNodeView: View {
    let entry: DiskEntry
    let tree: DiskTreeStore
    @State private var expanded = false

    private var childEntries: [DiskEntry]? {
        guard entry.isDirectory else { return nil }
        return tree.nodes[entry.path]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if entry.isDirectory {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                } else {
                    Spacer(minLength: 20).frame(width: 14)
                }
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .font(.caption)
                Text(entry.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                sizeLabel
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                if entry.isDirectory { expanded.toggle() }
            }
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
                Button("复制完整路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                }
            }
            .onChange(of: expanded) { _, isOpen in
                guard isOpen else { return }
                Task { await tree.expand(entry) }
            }

            if expanded, let children = childEntries {
                ForEach(children) { child in
                    DiskTreeNodeView(entry: child, tree: tree)
                        .padding(.leading, 18)
                }
            }
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if let size = entry.size {
            Text(IOFormat.capacity(size))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .trailing)
        }
    }
}

private struct CapacityBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(ratio > 0.9 ? Color.red : (ratio > 0.75 ? Color.orange : Color.accentColor))
                    .frame(width: max(0, min(1, ratio)) * geometry.size.width)
            }
        }
    }
}
