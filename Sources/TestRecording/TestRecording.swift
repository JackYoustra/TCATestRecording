import ComposableArchitecture
import Foundation
import Algorithms
import AsyncAlgorithms

extension OutputStream {
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            let pointer = buffer.bindMemory(to: UInt8.self)
            assert(write(pointer.baseAddress!, maxLength: buffer.count) == buffer.count)
        }
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

public enum LogMessage<State, Action, UserDependencyAction> {
    case state(State)
    case action(Action)
    case dependency(UserDependencyAction)
}

extension LogMessage: Encodable where State: Encodable, Action: Encodable, UserDependencyAction: Encodable {
    func write(to outputStream: OutputStream, with encoder: JSONEncoder) {
        outputStream.write(try! encoder.encode(self))
        // write newline
        outputStream.write(",\n".data(using: .utf8)!)
    }
}

extension LogMessage: Decodable where State: Decodable, Action: Decodable, UserDependencyAction: Decodable {}

public typealias ReplayRecordOf<T: ReducerProtocol, DependencyAction: Decodable> = ReplayRecord<T.State, T.Action, DependencyAction> where T.State: Decodable, T.Action: Decodable

public enum ReplayAction<State: Decodable, Action: Decodable, UserDependencyAction: Decodable>: Decodable {
    case quantum(ReplayQuantum<State, Action>)
    case dependencySet(UserDependencyAction)
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

public struct ReplayRecord<State: Decodable, Action: Decodable, UserDependencyAction: Decodable>: Decodable {
    typealias LogEntry = LogMessage<State, Action, UserDependencyAction>
    public typealias UserReplayAction = ReplayAction<State, Action, UserDependencyAction>
    
    public let start: State

    public let replayActions: [UserReplayAction]
    
    public init(url: URL) throws {
        let decoder = JSONDecoder()
        let contents = try String(contentsOf: url)
        print(contents)
        self = try decoder.decode(Self.self, from: "[\(contents)]".data(using: .utf8)!)
    }
    
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        self.start = try container.decode(casePath: /LogEntry.state)
        var quantums: [UserReplayAction] = []
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
    
    init(start: State, replayActions: [UserReplayAction]) {
        self.start = start
        self.replayActions = replayActions
    }
}

protocol DependencyOneUseSetting {
    func resetDependency(on: inout DependencyValues)
}

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable, UserDependencyAction: Equatable { }

extension ReplayRecord where State: Equatable, Action: Equatable, UserDependencyAction: Equatable & DependencyOneUseSetting {
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
                dep.resetDependency(on: &store.dependencies)
            }
        }
    }
}

class UncheckedIsFirst {
    var isFirst: Bool = true
}

public actor SharedThing<State: Encodable, Action: Encodable, DependencyAction: Encodable> {
    public typealias LogEntry = LogMessage<State, Action, DependencyAction>
    let outputStream: OutputStream
    private let send: AsyncStream<LogEntry>.Continuation
    let stream: AsyncStream<LogEntry>
    nonisolated let uncheckedIsFirst = UncheckedIsFirst()
    
    nonisolated public func submit(_ entry: LogEntry) {
        send.yield(entry)
    }
    
    var waiter: Task<(), Never>! = nil
    
    func waitToFinish() async {
        send.finish()
        _ = await waiter.value
    }
    
    init(url: URL, options: JSONEncoder.OutputFormatting? = nil) async {
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
        waiter = Task(priority: .background) {
            for await entry in stream {
                print("Entry is \(entry)")
                // Encode in background
                entry.write(to: outputStream, with: encoder)
            }
            outputStream.close()
        }
    }
}

extension ReplayQuantum: Equatable where State: Equatable, Action: Equatable {}
extension ReplayAction: Equatable where State: Equatable, Action: Equatable, UserDependencyAction: Equatable {}

extension ReducerProtocol where State: Encodable, Action: Encodable {
    public func record<DependencyAction: Encodable>(to url: URL, options: JSONEncoder.OutputFormatting? = nil, modificationClosure: _RecordReducer<Self, DependencyAction>.ModificationClosure? = nil) async -> _RecordReducer<Self, DependencyAction> {
        _RecordReducer(base: self, submitter: await SharedThing<State, Action, DependencyAction>.init(url: url, options: options), modificationClosure: modificationClosure)
    }
    
    public func record<DependencyAction: Encodable>(with submitter: SharedThing<State, Action, DependencyAction>, modificationClosure: _RecordReducer<Self, DependencyAction>.ModificationClosure? = nil) -> _RecordReducer<Self, DependencyAction> {
        _RecordReducer(base: self, submitter: submitter, modificationClosure: modificationClosure)
    }
    
    public func record(with submitter: SharedThing<State, Action, NeverCodable>) -> _RecordReducer<Self, NeverCodable> {
        _RecordReducer(base: self, submitter: submitter, modificationClosure: nil)
    }
}

public struct NeverCodable: Equatable, Codable, DependencyOneUseSetting {
    func resetDependency(on: inout Dependencies.DependencyValues) {
        fatalError("Shouldn't call anything on nothing")
    }
    private init() {} }

public struct _RecordReducer<Base: ReducerProtocol, DependencyAction: Encodable>: ReducerProtocol where Base.State: Encodable, Base.Action: Encodable {
  @usableFromInline
  let base: Base

  @usableFromInline
    let submitter: SharedThing<Base.State, Base.Action, DependencyAction>?
    
    public typealias ModificationClosure = (inout DependencyValues, @escaping (DependencyAction) -> ()) -> ()
    
    let modificationClosure: ModificationClosure?

  @usableFromInline
  init(base: Base, submitter: SharedThing<Base.State, Base.Action, DependencyAction>?, modificationClosure: ModificationClosure?) {
    self.base = base
    self.submitter = submitter
      self.modificationClosure = modificationClosure
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
          let effects = withDependencies { values in
              modificationClosure?(&values, {
                  submitter.submit(.dependency($0))
              })
//              values.withRandomNumberGenerator = .init(RecordedRNG(values.withRandomNumberGenerator, submission: { submitter.submit(.dependency(.setRNG($0))) }))
          } operation: {
              self.base.reduce(into: &state, action: action)
          }
        // Need to be synchronous or else may be out of order! Try to keep to fast path
        // Submit new state
        submitter.submit(.state(state))
        return effects
      }
    #endif
    return self.base.reduce(into: &state, action: action)
  }
}
