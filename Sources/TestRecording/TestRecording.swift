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
                outputStream.write(",\n".data(using: .utf8)!)
                isFirst = false
            }
            // encode action
            outputStream.write(try! encoder.encode(action))
            outputStream.write(",\n".data(using: .utf8)!)
            // encode newState
            outputStream.write(try! encoder.encode(newState))
            outputStream.write(",\n".data(using: .utf8)!)
//            defer { outputStream.close() }
            
        }
    }
}

public typealias ReplayRecordOf<T: ReducerProtocol> = ReplayRecord<T.State, T.Action> where T.State: Decodable, T.Action: Decodable

public struct ReplayQuantum<State: Decodable, Action: Decodable>: Decodable {
    public let action: Action
    public let result: State
}

public struct ReplayRecord<State: Decodable, Action: Decodable>: Decodable {
    public let start: State

    public let quantums: [ReplayQuantum<State, Action>]
    
    public init(url: URL) throws {
        let decoder = JSONDecoder()
        let contents = try String(contentsOf: url)
        self = try decoder.decode(Self.self, from: "[\(contents)]".data(using: .utf8)!)
    }
    
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        self.start = try container.decode(State.self)
        var quantums: [ReplayQuantum<State, Action>] = []
        while !container.isAtEnd {
            let quantum = ReplayQuantum(action: try container.decode(Action.self), result: try container.decode(State.self))
            quantums.append(quantum)
        }
        self.quantums = quantums
    }
    
    init(start: State, quantums: [ReplayQuantum<State, Action>]) {
        self.start = start
        self.quantums = quantums
    }
}

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable {}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
