import ComposableArchitecture
import Foundation
import Algorithms

extension _ReducerPrinter where State: Encodable, Action: Encodable  {
    public static func replayWriter(url: URL, options: JSONEncoder.OutputFormatting? = nil) -> Self {
        var isFirst = true
        // Create a file write stream
        assert(!FileManager.default.fileExists(atPath: url.path))
        guard let outputStream = OutputStream(url: url, append: false) else {
            fatalError("Unable to create file")
        }
        outputStream.open()
        let encoder = JSONEncoder()
        if let options {
            encoder.outputFormatting = options
        }
        
        return Self { action, oldState, newState in
            if isFirst {
                // encode oldState as the initial state
                outputStream.write(encoder.encode(oldState)!, maxLength: .max)
                // write newline
                outputStream.write("\n".data(using: .utf8)!, maxLength: 1)
                isFirst = false
            }
            // encode action
            outputStream.write(encoder.encode(action)!, maxLength: .max)
            outputStream.write("\n".data(using: .utf8)!, maxLength: 1)
            // encode newState
            outputStream.write(encoder.encode(newState)!, maxLength: .max)
            outputStream.write("\n".data(using: .utf8)!, maxLength: 1)
//            defer { outputStream.close() }
            
        }
    }
}

struct ReplayRecord<State: Decodable, Action: Decodable> {
    let start: State
    
    struct ReplayQuantum: Decodable {
        let action: Action
        let result: State
    }

    let quantums: [ReplayQuantum]

    init(from url: URL) async throws {
        // read file, split on newlines, and then decode
        // with a task group
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A)
        let decoder = JSONDecoder()
        async let quantums = withThrowingTaskGroup(of: ReplayQuantum.self) { group in
            var quantums = [ReplayQuantum]()
            quantums.reserveCapacity(lines.count - 1)
            for chunk in lines.dropFirst(1).chunks(ofCount: 2) {
                assert(chunk.count == 2)
                let (actionLine, resultLine) = (chunk[0], chunk[1])
                group.addTask {
                    let action = try decoder.decode(Action.self, from: actionLine)
                    let state = try decoder.decode(State.self, from: resultLine)
                    return ReplayQuantum(action: try await action, result: try await state)
                }
            }
            for try await quantum in group {
                quantums.append(quantum)
            }
            return quantums
        }
        self.start = try decoder.decode(State.self, from: lines[0])
        self.quantums = try await quantums
    }
}
