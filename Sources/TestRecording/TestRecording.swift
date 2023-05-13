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
//    mutating func record() -> [(SettingType) -> ()]
    
//    func eventStream() -> [AsyncStream<Any>]
    
    func apply() -> Self
}

//func recordDependency<T: RecordedDependency>(_ value: inout T) {
//    for setter in value.record() {
//        setter { (functionToSet: inout T.FunctionToSetType) in
//            let swappedfunction = functionToSet
//            functionToSet = { originalArg in
//                let value = swappedfunction(originalArg)
//                sReplayQ.submit(originalArg, value)
//                return value
//            }
//        }
//    }
//}

struct RecordedRNG: RandomNumberGenerator {
    let isolatedInner: WithRandomNumberGenerator
    
    init(_ wrng: WithRandomNumberGenerator) {
        isolatedInner = wrng
    }
    
    func next() -> UInt64 {
        var num: UInt64! = nil
        isolatedInner { rng in
            num = rng.next()
            sReplayQ.submit(RecordedRNG.self, num!)
        }
        return num
    }
}

struct PlaybackRNG<S: IteratorProtocol>: RandomNumberGenerator where S.Element == UInt64 {
    var numbers: S
    
    mutating func next() -> UInt64 {
        numbers.next()!
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

extension WithRandomNumberGenerator: RecordedDependency {
    func apply() -> Self {
        Self.init(RecordedRNG(self))
    }
}

extension ReducerProtocol {
    func wrapReducerDependency() -> _DependencyKeyWritingReducer<Self> {
        self.transformDependency(\.self) { deps in
            deps.withRandomNumberGenerator = .init(RecordedRNG(deps.withRandomNumberGenerator))
            
        }
    }
    
    func injectRecordedDependency() -> _DependencyKeyWritingReducer<Self> {
        self.transformDependency(\.self) { deps in
            deps.withRandomNumberGenerator = .init(RecordedRNG(deps.withRandomNumberGenerator))
            
        }
    }
}

public enum DependencyAction: Codable, Equatable {
    case setRNG(UInt64)
}

enum LogMessage<State, Action> {
    case state(State)
    case action(Action)
    case dependency(DependencyAction)
}

extension LogMessage: Encodable where State: Encodable, Action: Encodable {
    func write(to outputStream: OutputStream, with encoder: JSONEncoder) {
        outputStream.write(try! encoder.encode(self))
        // write newline
        outputStream.write(",\n".data(using: .utf8)!)
    }
}

extension LogMessage: Decodable where State: Decodable, Action: Decodable {}

public extension _ReducerPrinter where State: Encodable, Action: Encodable  {
    internal typealias LogEntry = LogMessage<State, Action>
    
    static func replayWriter(url: URL, options: JSONEncoder.OutputFormatting? = nil) -> Self {
        var isFirst = true
        // Create a file write stream
        if FileManager.default.fileExists(atPath: url.path) {
            try! FileManager.default.removeItem(at: url)
        }
        guard let outputStream = OutputStream(url: url, append: false) else {
            fatalError("Unable to create file")
        }
        let lockedOutputStream = LockIsolated(outputStream)
        outputStream.open()
        let encoder = JSONEncoder()
        if let options {
            encoder.outputFormatting = options
        }
        
        let depString = "DEP:"
        
        // dependency time
        Task {
            for await entry in sReplayQ.stream {
                print("Got entry \(entry)")
                lockedOutputStream.withValue { outputStream in
                    LogEntry.dependency(.setRNG(entry.value as! UInt64)).write(to: outputStream, with: encoder)
                }
            }
        }
        
        return Self { action, oldState, newState in
            lockedOutputStream.withValue { outputStream in
                if isFirst {
                    // encode oldState as the initial state
                    LogEntry.state(oldState)
                        .write(to: outputStream, with: encoder)
                }
                isFirst = false
                // encode action
                LogEntry.action(action)
                    .write(to: outputStream, with: encoder)
                // encode newState
                LogEntry.state(newState)
                    .write(to: outputStream, with: encoder)
            }
//            defer { outputStream.close() }
            
        }
    }
}

public typealias ReplayRecordOf<T: ReducerProtocol> = ReplayRecord<T.State, T.Action> where T.State: Decodable, T.Action: Decodable

public enum ReplayAction<State: Decodable, Action: Decodable>: Decodable {
    case quantum(ReplayQuantum<State, Action>)
    case dependencySet(DependencyAction)
}

public struct ReplayQuantum<State: Decodable, Action: Decodable>: Decodable {
    public let action: Action
    public let result: State
}

extension UnkeyedDecodingContainer {
    mutating func decode<R: Decodable, V: Decodable>(casePath: CasePath<R, V>) throws -> V {
        let e = try self.decode(R.self)
        return casePath.extract(from: e)!
    }
}

public struct ReplayRecord<State: Decodable, Action: Decodable>: Decodable {
    typealias LogEntry = LogMessage<State, Action>
    
    public let start: State

    public let replayActions: [ReplayAction<State, Action>]
    
    public init(url: URL) throws {
        let decoder = JSONDecoder()
        let contents = try String(contentsOf: url)
        print(contents)
        self = try decoder.decode(Self.self, from: "[\(contents)]".data(using: .utf8)!)
    }
    
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        self.start = try container.decode(casePath: /LogEntry.state)
        var quantums: [ReplayAction<State, Action>] = []
        var inProgressAction: Action? = nil
        while !container.isAtEnd {
            let entry = try container.decode(LogEntry.self)
            print(entry)
            switch entry {
            case let .action(action):
                assert(inProgressAction == nil)
                inProgressAction = action
            case let .state(state):
                assert(inProgressAction != nil)
                let quantum = ReplayQuantum(action: inProgressAction!, result: state)
                inProgressAction = nil
                quantums.append(.quantum(quantum))
            case let .dependency(dep):
                quantums.append(.dependencySet(dep))
            }
            
        }
        self.replayActions = quantums
    }
    
    init(start: State, replayActions: [ReplayAction<State, Action>]) {
        self.start = start
        self.replayActions = replayActions
    }
}

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable {
    @MainActor
    func test<Reducer: ReducerProtocol<State, Action>>(_ reducer: Reducer, file: StaticString = #file, line: UInt = #line) {
        let store = TestStore(
            initialState: start,
            reducer: reducer
        )
        
        for action in replayActions {
            switch action {
            case let .quantum(quantum):
                store.send(quantum.action, assert: {
                    $0 = quantum.result
                }, file: file, line: line)
            case let .dependencySet(dep):
                switch dep {
                case let .setRNG(num):
                    store.dependencies.withRandomNumberGenerator = .init(SingleRNG(n: num))
                }
                break
                
            }
        }
    }
}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
extension ReplayAction: Equatable where State: Equatable, Action: Equatable {}
