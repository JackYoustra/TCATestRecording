import ComposableArchitecture
import Foundation
import Algorithms

extension OutputStream {
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            let pointer = buffer.bindMemory(to: UInt8.self)
            write(pointer.baseAddress!, maxLength: buffer.count)
        }
    }
}

public extension _ReducerPrinter where State: Encodable, Action: Encodable  {
    static func replayWriter(url: URL, options: JSONEncoder.OutputFormatting? = nil) -> Self {
        var isFirst = true
        // Create a file write stream
        if FileManager.default.fileExists(atPath: url.path) {
            try! FileManager.default.removeItem(at: url)
        }
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
                outputStream.write(try! encoder.encode(oldState))
                // write newline
                outputStream.write("\n".data(using: .utf8)!)
                isFirst = false
            }
            // encode action
            outputStream.write(try! encoder.encode(action))
            outputStream.write("\n".data(using: .utf8)!)
            // encode newState
            outputStream.write(try! encoder.encode(newState))
            outputStream.write("\n".data(using: .utf8)!)
//            defer { outputStream.close() }
            
        }
    }
}

public typealias ReplayRecordOf<T: ReducerProtocol> = ReplayRecord<T.State, T.Action> where T.State: Decodable, T.Action: Decodable

public struct ReplayQuantum<State: Decodable, Action: Decodable>: Decodable {
    public let action: Action
    public let result: State
}

public struct ReplayRecord<State: Decodable, Action: Decodable> {
    public let start: State

    public let quantums: [ReplayQuantum<State, Action>]

    public init(from url: URL) async throws {
        // read file, split on newlines, and then decode
        // with a task group
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A)
        let decoder = JSONDecoder()
        async let quantums = lines.dropFirst(1).chunks(ofCount: 2).parallelMap { chunk in
            assert(chunk.count == 2)
            let (actionLine, resultLine) = (chunk.first!, chunk.last!)
            let action = try decoder.decode(Action.self, from: actionLine)
            let state = try decoder.decode(State.self, from: resultLine)
            return ReplayQuantum(action: action, result: state)
        }
        self.start = try decoder.decode(State.self, from: lines[0])
        self.quantums = try await quantums
    }
    
    init(start: State, quantums: [ReplayQuantum<State, Action>]) {
        self.start = start
        self.quantums = quantums
    }
}

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable {}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
