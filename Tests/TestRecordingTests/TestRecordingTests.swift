import XCTest
import ComposableArchitecture
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

@MainActor
class TestRecordingTests: XCTestCase {
    func testExample() async throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        let store = TestStore(
            initialState: AppReducer.State(),
            reducer: AppReducer()
                ._printChanges(.replayWriter(url: logLocation, options: [.prettyPrinted]))
        )
        await store.send(.increment) {
            $0.count = 1
        }

        await store.send(.increment) {
            $0.count = 2
        }
        print(try String.init(contentsOfFile: logLocation.path))
        // Assert contents at test.log matches "hi"
        let data = try await ReplayRecordOf<AppReducer>(from: logLocation)
        let expected = ReplayRecordOf<AppReducer>(start: .init(count: 0), quantums: [
            .init(action: .increment, result: .init(count: 1)),
            .init(action: .increment, result: .init(count: 2)),
        ])
        XCTAssertNoDifference(expected, data)
    }
}
