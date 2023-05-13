import Lumos
import XCTest

class IgnoreIssueResilientTests: XCTestCase {
    func testFailureWorkaround() {
        ignoreIssueResilient {
            
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
    func ignoreIssueResilient(_ execute: () throws -> ()) rethrows {
        Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        defer {
            Lumos.swizzle(type: .instance, originalClass: XCTestCase.self, originalSelector: NSSelectorFromString("_recordIssue:"), swizzledClass: TestRecordingDummyStore.self, swizzledSelector: #selector(TestRecordingDummyStore._recordIssue(_:)))
        }
        try execute()
    }
}

private class TestRecordingDummyStore: NSObject {
    @objc dynamic func _recordIssue(_ issue: XCTIssue) {
    }
}
