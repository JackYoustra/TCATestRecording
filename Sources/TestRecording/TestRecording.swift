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

struct ReplayQ<T> {
    struct Entry {
        let key: Any
        let value: T
    }
    
    private var send: AsyncStream<Entry>.Continuation
    var stream: AsyncStream<Entry>
    
    func submit(_ key: Any, _ value: T) {
        send.yield(Entry(key: key, value: value))
    }
    
    init() {
        var c: AsyncStream<Entry>.Continuation! = nil
        let asyncQueue = AsyncStream(Entry.self, bufferingPolicy: .unbounded, {
            c = $0
        })
        send = c
        stream = asyncQueue
    }
}

let sReplayQ = ReplayQ<Any>()

protocol RecordedDependency {
    // Take a list of functions, make every function do what they were going to do,
    // but also send their value to sReplayQ
    typealias FunctionToSetType = (Any) -> (Any)
    typealias SettingType = ((_ q: inout FunctionToSetType) -> ())
    mutating func record() -> [(SettingType) -> ()]
    
    func eventStream() -> [AsyncStream<Any>]
}

func recordDependency<T: RecordedDependency>(_ value: inout T) {
    for setter in value.record() {
        setter { (functionToSet: inout T.FunctionToSetType) in
            let swappedfunction = functionToSet
            functionToSet = { originalArg in
                let value = swappedfunction(originalArg)
                sReplayQ.submit(originalArg, value)
                return value
            }
        }
    }
}

extension ReducerProtocol {
    func wrapReducerDependency() -> _DependencyKeyWritingReducer<Self> {
        self.transformDependency(\.self) { deps in
            // mirror deps
            let mirror = Mirror(reflecting: deps)
            for child in mirror.children {
                // implicit key: mirror.name
                // value generated to... stream?? global??
//                (deps[keyPath: child] as? RecordedDependency)?.record()
//                deps[keyPath: child] = deps[keyPath: child]
            }
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
        
        // dependency time
        Task {
            for await dependencySend in sReplayQ.stream {
                
            }
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

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable {
    @MainActor
    func test<Reducer: ReducerProtocol<State, Action>>(_ reducer: Reducer, file: StaticString = #file, line: UInt = #line) {
        let store = TestStore(
            initialState: start,
            reducer: reducer
        )
        
        for quantum in quantums {
            store.send(quantum.action, assert: {
                $0 = quantum.result
            }, file: file, line: line)
        }
    }
}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
