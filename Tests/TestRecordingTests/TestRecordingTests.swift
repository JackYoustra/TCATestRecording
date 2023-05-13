import XCTest
@_spi(Internals) import ComposableArchitecture
@testable import TestRecording

struct SequentialRNG: RandomNumberGenerator {
    var count = UInt64(0)
    mutating func next() -> UInt64 {
        defer { count += 1 }
        print("Count is \(count)")
        return count
    }
}

struct AppReducer: ReducerProtocol {
    struct State: Equatable, Codable {
        var count: Int
        
        init(count: Int = 0) {
            self.count = count
        }
    }

    enum Action: Equatable, Codable {
        case increment
        case setCount(Int)
        case randomizeCount
    }
    
    @Dependency(\.withRandomNumberGenerator) var rng

    var body: some ReducerProtocolOf<Self> {
        Reduce { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none
            case .setCount(let count):
                state.count = count
                return .none
            case .randomizeCount:
                state.count = rng {
                    Int(truncatingIfNeeded: $0.next())
                }
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
            let submitter = SharedThing<AppReducer.State, AppReducer.Action>(url: logLocation, options: optionSet)
            let store = TestStore(
                initialState: AppReducer.State(),
                reducer: AppReducer()
                    .wrapReducerDependency()
                    .record(with: submitter)
//                    ._printChanges(.replayWriter(url: logLocation, options: optionSet))
            )
            await store.send(.increment) {
                $0.count = 1
            }
            
            await store.send(.increment) {
                $0.count = 2
            }
            
            await submitter.waitToFinish()

            // Assert contents at test.log matches "hi"
            let data = try ReplayRecordOf<AppReducer>(url: logLocation)
            let expected = ReplayRecordOf<AppReducer>(start: .init(count: 0), replayActions: [
                .quantum(.init(action: .increment, result: .init(count: 1))),
                .quantum(.init(action: .increment, result: .init(count: 2))),
            ])
            XCTAssertNoDifference(expected, data)
            
            // And finally, the test should pass
            data.test(AppReducer())
            
            // Make sure the tests don't pass if they shouldn't
            let fails: [ReplayRecordOf<AppReducer>] = [
                .init(start: .init(count: 0), replayActions: []),
                .init(start: .init(count: 1), replayActions: [
                    .quantum(.init(action: .increment, result: .init(count: 1))),
                             .quantum(.init(action: .increment, result: .init(count: 2))),
                ]),
                .init(start: .init(count: 0), replayActions: [
                    .quantum(.init(action: .increment, result: .init(count: 2))),
                             .quantum(.init(action: .increment, result: .init(count: 2))),
                ]),
            ]
            
            for fail in fails {
                ignoreIssueResilient {
                    fail.test(AppReducer())
                }
            }
        }
    }
    
    func testRandomized() throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        let store = TestStore(
            initialState: AppReducer.State(),
            reducer: AppReducer()
                .wrapReducerDependency()
                .dependency(\.withRandomNumberGenerator, .init(SequentialRNG()))
//                ._printChanges(.replayWriter(url: logLocation))
                .record(to: logLocation)
        )
        store.send(.increment) { $0.count = 1 }
        store.send(.randomizeCount) { $0.count = 0 }
        store.send(.randomizeCount) { $0.count = 1 }
        store.send(.randomizeCount) { $0.count = 2 }
        let data = try ReplayRecordOf<AppReducer>(url: logLocation)
        let expected = ReplayRecordOf<AppReducer>(start: .init(count: 0), replayActions: [
            .quantum(.init(action: .increment, result: .init(count: 1))),
            .dependencySet(.setRNG(0)),
            .quantum(.init(action: .randomizeCount, result: .init(count: 0))),
            .dependencySet(.setRNG(1)),
            .quantum(.init(action: .randomizeCount, result: .init(count: 1))),
            .dependencySet(.setRNG(2)),
            .quantum(.init(action: .randomizeCount, result: .init(count: 2))),
        ])
        XCTAssertNoDifference(expected, data)
        
        data.test(AppReducer())
    }
}
