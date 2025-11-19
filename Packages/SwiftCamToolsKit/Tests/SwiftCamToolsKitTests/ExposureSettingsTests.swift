import XCTest
@testable import SwiftCamCore

final class ExposureSettingsTests: XCTestCase {
    func testQueueMaintainsFIFOOrder() {
        let queue = ExposureQueue()
        queue.enqueue(ExposureSettings(iso: 100, duration: 100))
        queue.enqueue(ExposureSettings(iso: 200, duration: 200))

        XCTAssertEqual(queue.dequeue()?.iso, 100)
        XCTAssertEqual(queue.dequeue()?.iso, 200)
    }
}
