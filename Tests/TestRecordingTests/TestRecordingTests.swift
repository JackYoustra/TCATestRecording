import XCTest
import ComposableArchitecture
@testable import TestRecording
import Lumos

struct AppReducer: ReducerProtocol {
    struct State: Equatable, Codable {
        var count: Int
        
        init(count: Int = 0) {
            self.count = count
        }
    }

    enum Action: Equatable, Codable {
        case increment
    }

    var body: some ReducerProtocolOf<Self> {
        Reduce { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            }
        }
    }
}

@available(macOS 13.0, *)
@MainActor
class TestRecordingTests: XCTestCase {
    func testExample() async throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        for optionSet in [[], JSONEncoder.OutputFormatting.prettyPrinted] {
            let store = TestStore(
                initialState: AppReducer.State(),
                reducer: AppReducer()
                    ._printChanges(.replayWriter(url: logLocation, options: optionSet))
            )
            await store.send(.increment) {
                $0.count = 1
            }
            
            await store.send(.increment) {
                $0.count = 2
            }
            // Assert contents at test.log matches "hi"
            let data = try ReplayRecordOf<AppReducer>(url: logLocation)
            let expected = ReplayRecordOf<AppReducer>(start: .init(count: 0), quantums: [
                .init(action: .increment, result: .init(count: 1)),
                .init(action: .increment, result: .init(count: 2)),
            ])
            XCTAssertNoDifference(expected, data)
            
            // And finally, the test should pass
            data.test(AppReducer())
            
            // Make sure the tests don't pass if they shouldn't
            let fails: [ReplayRecordOf<AppReducer>] = [
                .init(start: .init(count: 0), quantums: []),
                .init(start: .init(count: 1), quantums: [
                    .init(action: .increment, result: .init(count: 1)),
                    .init(action: .increment, result: .init(count: 2)),
                ]),
                .init(start: .init(count: 0), quantums: [
                    .init(action: .increment, result: .init(count: 2)),
                    .init(action: .increment, result: .init(count: 2)),
                ]),
            ]

            for fail in fails {
                ignoreIssueResilient {
                    fail.test(AppReducer())
                }
            }
        }
    }
    
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
