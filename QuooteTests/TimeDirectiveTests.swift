import XCTest
@testable import Quoote

final class TimeDirectiveTests: XCTestCase {
    private let calendar = Calendar.current
    // 2026-10-01 17:00 local.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 17))!

    private func hourMinute(_ date: Date) -> [Int] {
        let c = calendar.dateComponents([.day, .hour, .minute], from: date)
        return [c.day!, c.hour!, c.minute!]
    }

    func testBareTimeIsToday() throws {
        let parsed = try XCTUnwrap(TimeDirective.parse("@3pm\n\nHello", now: now))
        XCTAssertEqual(hourMinute(parsed.date), [1, 15, 0])
        XCTAssertEqual(parsed.body, "Hello")
    }

    func testTimeWithMinutesAndTwentyFourHour() throws {
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "3:30 pm", now: now))), [1, 15, 30])
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "09:15", now: now))), [1, 9, 15])
    }

    func testFutureTimeMeansYesterday() throws {
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "9pm", now: now))), [30, 21, 0])
    }

    func testRelative() throws {
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "3 hours ago", now: now))), [1, 14, 0])
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "20 min ago", now: now))), [1, 16, 40])
        XCTAssertEqual(hourMinute(try XCTUnwrap(TimeDirective.date(from: "an hour ago", now: now))), [1, 16, 0])
    }

    func testNonDirectivesAreLeftAlone() {
        XCTAssertNil(TimeDirective.parse("Hello @3pm", now: now))
        XCTAssertNil(TimeDirective.parse("@alice said hi", now: now))
        XCTAssertNil(TimeDirective.parse("@", now: now))
    }
}
