import ComposableArchitecture
import Foundation
import Algorithms
import AsyncAlgorithms

extension OutputStream {
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            print("Buffer count is \(buffer.count)")
            let pointer = buffer.bindMemory(to: UInt8.self)
            assert(write(pointer.baseAddress!, maxLength: buffer.count) == buffer.count)
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

public enum LogMessage<State, Action> {
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

class UncheckedIsFirst {
    var isFirst: Bool = true
}

public actor SharedThing<State: Encodable, Action: Encodable> {
    public typealias LogEntry = LogMessage<State, Action>
    let outputStream: OutputStream
    private let send: AsyncStream<LogEntry>.Continuation
    let stream: AsyncStream<LogEntry>
    nonisolated let uncheckedIsFirst = UncheckedIsFirst()
    
    nonisolated public func submit(_ entry: LogEntry) {
        send.yield(entry)
    }
    
    let waiter: ActorIsolated<()> = .init(())
    
    func waitToFinish() async {
        send.finish()
        _ = await waiter.value
    }
    
    init(url: URL, options: JSONEncoder.OutputFormatting? = nil) {
        var c: AsyncStream<LogEntry>.Continuation! = nil
        let asyncQueue = AsyncStream(LogEntry.self, bufferingPolicy: .unbounded, {
            c = $0
        })
        send = c
        stream = asyncQueue
        
        guard let outputStream = OutputStream(url: url, append: false) else {
            fatalError("Unable to create file")
        }
        self.outputStream = outputStream
        outputStream.open()
        let encoder = JSONEncoder()
        if let options {
            encoder.outputFormatting = options
        }
        
        // writer task, detatcheded but implicitly tied to stream
        Task(priority: .background) {
            await waiter.withValue { _ in
                for await entry in merge(stream, sReplayQ.stream.map { .dependency(.setRNG($0.value as! UInt64)) }) {
                    print("Entry is \(entry)")
                    // Encode in background
                    entry.write(to: outputStream, with: encoder)
                }
                // TODO: Await the task list finishing? Can't think of a a way to do that...
                outputStream.close()
            }
        }
    }
}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
extension ReplayAction: Equatable where State: Equatable, Action: Equatable {}

extension ReducerProtocol where State: Encodable, Action: Encodable {
    public func record(to url: URL, options: JSONEncoder.OutputFormatting? = nil) -> _RecordReducer<Self> {
        _RecordReducer(base: self, submitter: SharedThing<State, Action>.init(url: url, options: options))
    }
    
    public func record(with submitter: SharedThing<State, Action>) -> _RecordReducer<Self> {
        _RecordReducer(base: self, submitter: submitter)
    }
}

public struct _RecordReducer<Base: ReducerProtocol>: ReducerProtocol where Base.State: Encodable, Base.Action: Encodable {
  @usableFromInline
  let base: Base

  @usableFromInline
    let submitter: SharedThing<Base.State, Base.Action>?

  @usableFromInline
  init(base: Base, submitter: SharedThing<Base.State, Base.Action>?) {
    self.base = base
    self.submitter = submitter
  }

//  @inlinable
  public func reduce(
    into state: inout Base.State, action: Base.Action
  ) -> EffectTask<Base.Action> {
    #if DEBUG
      if let submitter = self.submitter {
          if submitter.uncheckedIsFirst.isFirst {
              // Submit initial state. Would be great to if-gate!
              submitter.submit(.state(state))
              submitter.uncheckedIsFirst.isFirst = false
          }
        // Submit action
        submitter.submit(.action(action))
        let effects = self.base.reduce(into: &state, action: action)
        // Need to be synchronous or else may be out of order! Try to keep to fast path
        // Submit new state
        submitter.submit(.state(state))
        return effects
      }
    #endif
    return self.base.reduce(into: &state, action: action)
  }
}
