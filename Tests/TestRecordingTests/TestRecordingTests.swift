import XCTest
import ComposableArchitecture
import SnapshotTesting
@testable import TestRecording

struct SequentialRNG: RandomNumberGenerator {
    var count = UInt64(0)
    mutating func next() -> UInt64 {
        defer { count += 1 }
        return count
    }
}

struct RecordedRNG: RandomNumberGenerator {
    let isolatedInner: WithRandomNumberGenerator
    let submission: (UInt64) -> ()
    
    init(_ wrng: WithRandomNumberGenerator, submission: @escaping (UInt64) -> ()) {
        isolatedInner = wrng
        self.submission = submission
    }
    
    func next() -> UInt64 {
        var num: UInt64! = nil
        isolatedInner { rng in
            num = rng.next()
            submission(num)
        }
        return num
    }
}

struct SingleRNG: RandomNumberGenerator {
    var n: UInt64?
    
    init(n: UInt64) {
        self.n = n
    }
    
    mutating func next() -> UInt64 {
        defer {
            n = nil
        }
        return n!
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
            let submitter = await SharedThing<AppReducer.State, AppReducer.Action, NeverCodable>(url: logLocation, options: optionSet)
            let store = TestStore(
                initialState: AppReducer.State(),
                reducer: AppReducer()
                    .record(with: submitter)
            )
            await store.send(.increment) {
                $0.count = 1
            }
            
            await store.send(.increment) {
                $0.count = 2
            }
            
            await submitter.waitToFinish()

            // Assert contents at test.log matches "hi"
            let data = try ReplayRecordOf<AppReducer, NeverCodable>(url: logLocation)
            let expected = ReplayRecordOf<AppReducer, NeverCodable>(start: .init(count: 0), replayActions: [
                .quantum(.init(action: .increment, result: .init(count: 1))),
                .quantum(.init(action: .increment, result: .init(count: 2))),
            ])
            XCTAssertNoDifference(expected, data)
            
            // And finally, the test should pass
            data.test(AppReducer())
            
            // Make sure the tests don't pass if they shouldn't
            let fails: [ReplayRecordOf<AppReducer, NeverCodable>] = [
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
    
    public enum DependencyAction: Codable, Equatable, DependencyOneUseSetting {
        case setRNG(UInt64)

        func resetDependency(on deps: inout Dependencies.DependencyValues) {
            switch self {
            case let .setRNG(rn):
                deps.withRandomNumberGenerator = .init(SingleRNG(n: rn))
            }
        }
    }
    
    func testRandomized() async throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        let submitter = await SharedThing<AppReducer.State, AppReducer.Action, DependencyAction>(url: logLocation)
        let store = TestStore(
            initialState: AppReducer.State(),
            reducer: AppReducer()
                .record(with: submitter) { values, changeMission in
                    values.withRandomNumberGenerator = .init(RecordedRNG(values.withRandomNumberGenerator, submission: { changeMission(.setRNG($0)) }))
                }
                .dependency(\.withRandomNumberGenerator, .init(SequentialRNG()))
        )
        await store.send(.increment) { $0.count = 1 }
        await store.send(.randomizeCount) { $0.count = 0 }
        await store.send(.randomizeCount) { $0.count = 1 }
        await store.send(.randomizeCount) { $0.count = 2 }
        await submitter.waitToFinish()
        let data = try ReplayRecordOf<AppReducer, DependencyAction>(url: logLocation)
        let expected = ReplayRecordOf<AppReducer, DependencyAction>(start: .init(count: 0), replayActions: [
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

        // snapshot data.toTestCase()
        assertSnapshot(matching: data.toTestCase(), as: .lines, named: "testRandomizedGeneration")
    }
}
