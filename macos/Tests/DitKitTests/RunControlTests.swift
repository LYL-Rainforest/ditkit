import XCTest
import Foundation
@testable import DitKitCore

/// 记录 gate() 是否已返回，用于验证「暂停期间确实等待」。
private actor GateFlag {
    private(set) var fired = false
    func mark() { fired = true }
}

final class RunControlTests: XCTestCase {

    func testRunningGatePasses() async {
        let control = RunControl()
        let state = control.snapshot()
        let ok = await control.gate()
        XCTAssertEqual(state, .running)
        XCTAssertTrue(ok)
    }

    func testStopIsFinal() async {
        let control = RunControl()
        control.stop()
        let stopped = control.isStopped
        let first = await control.gate()
        control.resume()
        let stillStopped = control.isStopped
        let second = await control.gate()
        XCTAssertTrue(stopped)
        XCTAssertFalse(first)
        XCTAssertTrue(stillStopped, "停止后不可恢复")
        XCTAssertFalse(second)
    }

    func testPauseWaitsUntilResume() async throws {
        let control = RunControl()
        control.pause()
        let flag = GateFlag()
        let gateTask = Task {
            let ok = await control.gate()
            await flag.mark()
            return ok
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        let firedEarly = await flag.fired
        XCTAssertFalse(firedEarly, "暂停期间 gate() 不应返回")
        control.resume()
        let ok = await gateTask.value
        let state = control.snapshot()
        XCTAssertTrue(ok)
        XCTAssertEqual(state, .running)
    }

    func testStopWakesPausedGate() async throws {
        let control = RunControl()
        control.pause()
        let flag = GateFlag()
        let gateTask = Task {
            let ok = await control.gate()
            await flag.mark()
            return ok
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        let firedEarly = await flag.fired
        XCTAssertFalse(firedEarly, "暂停期间 gate() 不应返回")
        control.stop()
        let ok = await gateTask.value
        let stopped = control.isStopped
        XCTAssertFalse(ok, "停止后 gate() 必须返回 false")
        XCTAssertTrue(stopped)
    }
}
