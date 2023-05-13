import XCTest
import ComposableArchitecture
import TestRecording

struct AppReducer: ReducerProtocol {
    struct State: Equatable, Codable {
        var count = 0
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

class TestRecordingTests: XCTestCase {
    func testExample() throws {
        let logLocation = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test.log")
        let store = TestStore(
            initialState: AppReducer.State(),
            reducer: AppReducer()
                .replayWriter(url: logLocation, options: [.prettyPrinted])
        )
        store.assert(
            .send(.increment) {
                $0.count = 1
            },
            .send(.increment) {
                $0.count = 2
            }
        )
        // Assert contents at test.log matches "hi"
        let data = try Data(contentsOf: logLocation)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        print(json)
    }
}