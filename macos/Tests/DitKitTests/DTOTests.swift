import XCTest
@testable import DitKitCore

final class DTOTests: XCTestCase {
    func testDecodeHealth() throws {
        let json = #"{"status":"ok","version":"0.1.0","uptime_s":12,"smartctl":"/opt/homebrew/bin/smartctl"}"#
        let h = try JSONDecoder().decode(HealthResponse.self, from: Data(json.utf8))
        XCTAssertEqual(h.status, "ok")
        XCTAssertEqual(h.uptimeSeconds, 12)
        XCTAssertEqual(h.smartctl, "/opt/homebrew/bin/smartctl")
    }

    func testDecodeDisks() throws {
        let json = #"{"disks":[{"id":"disk_abc","name":"/dev/disk0","type":"nvme","protocol":"NVMe（高速固态硬盘接口）","label":"NVMe · disk0"}],"count":1}"#
        let r = try JSONDecoder().decode(DisksResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.disks.first?.protocolName, "NVMe（高速固态硬盘接口）")
    }

    func testDecodeChineseReport() throws {
        let json = """
        {
          "device":{"id":"disk_abc","name":"/dev/disk0","type":"nvme","protocol":"NVMe","label":"测试盘"},
          "overall":"健康","status":"ok","summary":"未发现异常","generated_at":"2026 年 11 月 09 日 20:57:57",
          "sections":[{"title":"一、设备信息","rows":[
            {"label":"当前温度","value":"35 摄氏度","status":"ok","note":"控制器报告的温度"},
            {"label":"异常断电次数","value":"9 次","status":"info"}
          ]}],
          "warnings":[],"messages":["smartctl 提示：读取 1 条错误信息日志失败"],
          "exit_code":4,"exit_notes":["退出码 4：以下状态位被置位","· 部分 SMART 或日志命令执行失败"]
        }
        """
        let r = try JSONDecoder().decode(ReportDTO.self, from: Data(json.utf8))
        XCTAssertEqual(r.overall, "健康")
        XCTAssertEqual(r.exitCode, 4)
        XCTAssertEqual(r.sections.first?.rows.count, 2)
        XCTAssertEqual(r.sections.first?.rows.first?.value, "35 摄氏度")
        XCTAssertNil(r.sections.first?.rows.last?.note)
        XCTAssertEqual(r.messages.count, 1)
    }

    func testSmartEndpointKeepsQueryString() {
        let path = Endpoints.smart(device: "disk_abc")
        XCTAssertTrue(path.contains("device=disk_abc"))
        XCTAssertFalse(path.contains("format="), "文本报告格式已移除，不应再有 format 参数")
        XCTAssertTrue(path.hasPrefix("/api/v1/smart?"))
    }

    // 联调冒烟：设置 DITKIT_REPORT_JSON 指向真实后端响应时才执行，常规测试不依赖服务。
    func testDecodeRealBackendResponse() throws {
        guard let path = ProcessInfo.processInfo.environment["DITKIT_REPORT_JSON"] else {
            throw XCTSkip("未提供真实后端响应，跳过冒烟测试")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let report = try JSONDecoder().decode(ReportDTO.self, from: data)
        XCTAssertFalse(report.sections.isEmpty)
        XCTAssertFalse(report.overall.isEmpty)
        XCTAssertTrue(report.sections.contains { section in
            section.rows.contains { $0.value.contains("摄氏度") }
        })
    }

    func testRuntimeInfoDecoding() throws {
        let json = #"{"port":51823,"token":"abc","pid":123,"version":"0.1.0","data_dir":"/tmp/ditkit","started_at":"2026-11-09T20:57:00+08:00"}"#
        let info = try JSONDecoder().decode(RuntimeInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.port, 51823)
        XCTAssertEqual(info.dataDir, "/tmp/ditkit")
    }
}
