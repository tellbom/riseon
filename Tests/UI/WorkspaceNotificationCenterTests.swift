import XCTest
@testable import RiseOn

/// Covers the testable half of task.md S14.1: notification wording. The
/// verification point itself ("后台完成时收到通知") needs a real device
/// with notification permission granted — not something a unit test in
/// this sandbox can confirm — so this tests `WorkspaceNotificationCenter.content`,
/// the pure function the actual scheduled notification's title/body come from.
final class WorkspaceNotificationCenterTests: XCTestCase {

    func test_content_succeeded_mentionsNameAndReadyToChat() {
        let (title, body) = WorkspaceNotificationCenter.content(for: "600519", name: "贵州茅台", outcome: .succeeded)
        XCTAssertEqual(title, "「贵州茅台」初始化完成")
        XCTAssertTrue(body.contains("600519"))
        XCTAssertTrue(body.contains("问答"))
    }

    func test_content_failed_mentionsStepNameAndRetry() {
        let (title, body) = WorkspaceNotificationCenter.content(for: "000001", name: "平安银行", outcome: .failed(.computeRuleScore))
        XCTAssertEqual(title, "「平安银行」初始化失败")
        XCTAssertTrue(body.contains("计算规则评分"), "must name the specific step that failed")
        XCTAssertTrue(body.contains("重试"))
    }

    func test_content_everyFailedStep_producesADistinctReadableStepName() {
        for step in InitStep.allCases {
            let (_, body) = WorkspaceNotificationCenter.content(for: "600519", name: "贵州茅台", outcome: .failed(step))
            XCTAssertTrue(body.contains(step.displayName), "step \(step) should be named in the notification body")
        }
    }

    func test_content_emptyName_fallsBackToCode() {
        let (title, _) = WorkspaceNotificationCenter.content(for: "600519", name: "", outcome: .succeeded)
        XCTAssertEqual(title, "「600519」初始化完成")
    }
}
