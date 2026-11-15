import Foundation
import Observation

public enum ConnectionState: String, Sendable {
    case idle
    case connecting
    case connected
    case failed
}

@MainActor
@Observable
public final class AppState {
    public var connection: ConnectionState = .idle
    public var statusMessage: String = "尚未连接本机采集后端"
    public var health: HealthResponse?
    public var disks: [DiskDTO] = []
    public var selectedDiskID: String?
    public var report: ReportDTO?
    public var errorMessage: String?

    @ObservationIgnored private var client: APIClient?

    public init() {}

    public func connect() async {
        connection = .connecting
        statusMessage = "正在连接本机采集后端…"
        errorMessage = nil
        do {
            // 安装包模式：先确保内嵌的 ditkitd 已启动（开发态会自动跳过）。
            try await DaemonController.shared.ensureRunning()
            let runtime = try RuntimeStore.load()
            let api = try APIClient(runtime: runtime)
            client = api
            let h: HealthResponse = try await api.request(Endpoints.health)
            health = h
            connection = .connected
            statusMessage = "已连接 · 后端版本 \(h.version) · smartctl：\(h.smartctl)"
            await refreshDisks()
        } catch {
            connection = .failed
            statusMessage = "连接失败"
            errorMessage = "\(error.localizedDescription)。请确认已安装 smartmontools（brew install smartmontools）后重新连接。"
        }
    }

    public func refreshDisks() async {
        guard let client else { return }
        do {
            let result: DisksResponse = try await client.request(Endpoints.disks)
            disks = result.disks
            if selectedDiskID == nil || !result.disks.contains(where: { $0.id == selectedDiskID }) {
                selectedDiskID = result.disks.first?.id
            }
            if let id = selectedDiskID {
                await selectDisk(id)
            } else {
                errorMessage = "smartctl 未发现可读取 SMART 的磁盘"
            }
        } catch {
            errorMessage = "读取磁盘列表失败：\(error.localizedDescription)"
        }
    }

    public func selectDisk(_ id: String) async {
        selectedDiskID = id
        guard let client else { return }
        do {
            let rep: ReportDTO = try await client.request(Endpoints.smart(device: id))
            report = rep
            errorMessage = nil
        } catch {
            errorMessage = "读取 SMART 报告失败：\(error.localizedDescription)"
        }
    }
}
