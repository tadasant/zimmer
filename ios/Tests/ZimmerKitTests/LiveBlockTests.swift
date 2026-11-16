import Foundation
import XCTest
@testable import ZimmerKit

final class LiveBlockTests: XCTestCase {
    private func event(_ text: String) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(text))
    }

    /// The event OpenAI sent on every attempt on 2026-11-15, word for word.
    func testOutOfCreditsAsOpenAISaidItIsABlock() throws {
        let sent = try event("""
        {"type":"error","event_id":"event_1","error":{"type":"insufficient_quota","code":"credit_balance_exhausted",
         "message":"You have no credits remaining. Add credits to continue using the API at https://platform.openai.com/settings/organization/billing/."}}
        """)
        XCTAssertEqual(LiveBlock(realtimeEvent: sent), .outOfCredits)
        XCTAssertTrue(LiveBlock.outOfCredits.message.contains("out of credits"))
    }

    func testEitherTheCodeOrTheTypeIsEnough() throws {
        for (type, code) in [("insufficient_quota", "something_new"), ("invalid_request_error", "insufficient_quota"),
                             ("invalid_request_error", "billing_hard_limit_reached"), ("invalid_request_error", "billing_not_active")] {
            let sent = try event(#"{"type":"error","error":{"type":"\#(type)","code":"\#(code)","message":"no"}}"#)
            XCTAssertEqual(LiveBlock(realtimeEvent: sent), .outOfCredits, "\(type) \(code)")
        }
    }

    /// Anything else is retried as before: a passing error, a refused send, a non-error event.
    func testOtherErrorsAndEventsAreNotBlocks() throws {
        for text in [
            #"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty","message":"x"}}"#,
            #"{"type":"error","error":{"type":"server_error","message":"x"}}"#,
            #"{"type":"error","error":{"type":"invalid_request_error","code":"rate_limit_exceeded","message":"x"}}"#,
            #"{"type":"error"}"#,
            #"{"type":"session.created","error":{"code":"insufficient_quota"}}"#,
        ] {
            XCTAssertNil(LiveBlock(realtimeEvent: try event(text)), text)
        }
    }

    func testTheBlockedTileFitsANarrowScreen() {
        XCTAssertEqual(LiveBlock.outOfCredits.titleVariants.count, 2)
        XCTAssertLessThanOrEqual(LiveBlock.outOfCredits.titleVariants[1].count, 10)
    }
}
