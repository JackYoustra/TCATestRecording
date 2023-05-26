import XCTest
import ComposableArchitecture
import SnapshotTesting
@testable import TestRecording

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
            let submitter = LogWriter<AppReducer.State, AppReducer.Action, DependencyAction>(url: logLocation, options: optionSet)
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
            let data = try ReplayRecordOf<AppReducer, DependencyAction>(url: logLocation)
            let expected = ReplayRecordOf<AppReducer, DependencyAction>(start: .init(count: 0), replayActions: [
                .quantum(.init(action: .increment, result: .init(count: 1))),
                .quantum(.init(action: .increment, result: .init(count: 2))),
            ])
            XCTAssertNoDifference(expected, data)
            
            // And finally, the test should pass
            data.test(AppReducer())
            
            // Make sure the tests don't pass if they shouldn't
            let fails: [ReplayRecordOf<AppReducer, DependencyAction>] = [
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
    
    func testRandomized() async throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        let submitter = LogWriter<AppReducer.State, AppReducer.Action, DependencyAction>(url: logLocation)
        let store = TestStore(
            initialState: AppReducer.State(),
            reducer: AppReducer()
                .record(with: submitter)
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
        assertSnapshot(matching: data.toTestCase(url: logLocation), as: .lines, named: "testRandomizedGeneration")
    }

    func testUUID() async throws {
        struct UUIDReducer: ReducerProtocol {
            struct State: Equatable, Codable {
                var uuid: UUID
            }

            enum Action: Equatable, Codable {
                case setUUID
            }

            @Dependency(\.uuid) var uuid

            var body: some ReducerProtocolOf<Self> {
                Reduce { state, action in
                    switch action {
                    case .setUUID:
                        state.uuid = uuid()
                        return .none
                    }
                }
            }
        }

        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test\(#line).log")
        
        let submitter = LogWriter<UUIDReducer.State, UUIDReducer.Action, DependencyAction>(url: logLocation)
        let uuidInt = LockIsolated(0)
        let initialUUID = UUID()
        let store = TestStore(
            initialState: UUIDReducer.State(uuid: initialUUID),
            reducer: UUIDReducer()
                .record(with: submitter)
                .dependency(\.uuid, .init { UUID(uuidInt.value) } )
        )

        await store.send(.setUUID) {
            $0.uuid = UUID(uuidInt.value)
        }

        uuidInt.setValue(52)

        await store.send(.setUUID) {
            $0.uuid = UUID(uuidInt.value)
        }

        await submitter.waitToFinish()

        let data = try ReplayRecordOf<UUIDReducer, DependencyAction>(url: logLocation)
        let expected = ReplayRecordOf<UUIDReducer, DependencyAction>(start: .init(uuid: initialUUID), replayActions: [
            .dependencySet(.setUUID(.init(0))),
            .quantum(.init(action: .setUUID, result: .init(uuid: .init(0)))),
            .dependencySet(.setUUID(.init(52))),
            .quantum(.init(action: .setUUID, result: .init(uuid: .init(52)))),
        ])
        XCTAssertNoDifference(expected, data)

        data.test(UUIDReducer())

        // snapshot data.toTestCase()
        assertSnapshot(matching: data.toTestCase(url: logLocation), as: .lines, named: "testRandomizedGeneration")
    }
}
