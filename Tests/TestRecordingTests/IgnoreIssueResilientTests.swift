import Lumos
import XCTest

class IgnoreIssueResilientTests: XCTestCase {
    func testFailureWorkaround() {
        XCTExpectFailure {
            ignoreIssueResilient {
                
            }
        }
    }
    
    func testFailureWorkaroundWithFailure() {
        XCTExpectFailure {
            XCTFail("uwu")
        }
        ignoreIssueResilient {
            XCTFail("owo")
        }
        XCTExpectFailure {
            XCTFail("ewe")
        }
    }
}

extension XCTestCase {
    func ignoreIssueResilient(_ execute: () throws -> (), file: StaticString = #file, line: UInt = #line) rethrows {
        Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        TestRecordingDummyStore.didRecord = false
        defer {
            TestRecordingDummyStore.didRecord = false
        }
        try execute()
        // Re-enable here so we can actually record a failure if it happens, lol
        Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        if !TestRecordingDummyStore.didRecord {
            XCTFail("Didn't have any error", file: file, line: line)
        }
    }

    func ignoreIssueResilient(_ execute: () async throws -> (), file: StaticString = #file, line: UInt = #line) async rethrows {
        Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        TestRecordingDummyStore.didRecord = false
        defer {
            TestRecordingDummyStore.didRecord = false
        }
        try await execute()
        // Re-enable here so we can actually record a failure if it happens, lol
        Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        if !TestRecordingDummyStore.didRecord {
            XCTFail("Didn't have any error", file: file, line: line)
        }
    }
}

fileprivate class TestRecordingDummyStore: NSObject {
    static var didRecord = false
    
    @objc dynamic func _recordIssue(_ issue: XCTIssue) {
        Self.didRecord = true
    }
}
