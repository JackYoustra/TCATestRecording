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

    public var asQuantum: ReplayQuantum<State, Action>? {
        guard case let .quantum(q) = self else { return nil }
        return q
    }

    public var asDependencySet: UserDependencyAction? {
        guard case let .dependencySet(d) = self else { return nil }
        return d
    }
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
        let contents = try String(contentsOf: url)
        self = try Self(string: contents)
    }

    public init(string: String) throws {
        let decoder = JSONDecoder()
        self = try decoder.decode(Self.self, from: "[\(string)]".data(using: .utf8)!)
    }
    
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        self.start = try container.decode(casePath: /LogEntry.state)
        var quantums: [UserReplayAction] = []
        var inProgressAction: Action? = nil
        while !container.isAtEnd {
            let entry = try container.decode(LogEntry.self)
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

    public func toTestCase(url: URL) -> String where State: Encodable, Action: Encodable, UserDependencyAction: Encodable {
        let stateQualifiedName = String(reflecting: State.self)
        let names = stateQualifiedName.split(separator: ".")
        assert(names.count >= 2)
        let hostModuleName = names[0]
        let reducerName = names[1]
        let userDependencyActionName = String(reflecting: UserDependencyAction.self)
        let encoder = JSONEncoder()
        let decodedName = "decoding"
        var testBody = ""
        for (offset, record) in replayActions.enumerated() {
            switch record {
            case .quantum:
                let quantumID = "quantum\(offset)"
                testBody += """
let \(quantumID) = \(decodedName).replayActions[\(offset)].asQuantum!
store.send(\(quantumID).action) {\n  $0 = \(quantumID).result\n}
"""
            case let .dependencySet(dep):
                // encode dep
                let dependencyString = try! String(data: encoder.encode(dep), encoding: .utf8)!
                testBody += """
// store.dependencies = \(dependencyString)"
\(decodedName).replayActions[\(offset)].asDependencySet!.resetDependency(on: &store.dependencies)
"""
            }

            testBody += "\n\n"
        }
        // Indent every line of testBody
        testBody = testBody.split(separator: "\n", omittingEmptySubsequences: false).map { "        \($0)" }.joined(separator: "\n")
return """
// AUTOGENERATED FILE

import ComposableArchitecture
import XCTest
import TestRecording
@testable import \(hostModuleName)

class \(reducerName)Tests: XCTestCase {

    func testRecording() throws {
        let logURL = URL(string: "\(url)")!
        let \(decodedName) = try ReplayRecord<\(reducerName).State, \(reducerName).Action, \(userDependencyActionName)>.init(url: logURL)
        let store = TestStore(
            initialState: \(decodedName).start,
            reducer: \(reducerName)()
        )

\(testBody)
    }
}
"""
    }
}

public protocol DependencyOneUseSetting {
    func resetDependency(on: inout DependencyValues)
}

extension ReplayRecord: Equatable where State: Equatable, Action: Equatable, UserDependencyAction: Equatable { }

extension ReplayRecord where State: Equatable, Action: Equatable, UserDependencyAction: DependencyOneUseSetting {
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

public actor LogWriter<State: Encodable, Action: Encodable, DependencyAction: Encodable> {
    public typealias LogEntry = LogMessage<State, Action, DependencyAction>
    let outputStream: OutputStream
    private let send: AsyncStream<LogEntry>.Continuation
    let stream: AsyncStream<LogEntry>
    nonisolated let uncheckedIsFirst = UncheckedIsFirst()
    
    nonisolated public func submit(_ entry: LogEntry) {
        send.yield(entry)
    }
    
    var waiter: Task<(), Never>! = nil
    
    public func waitToFinish() async {
        send.finish()
        _ = await waiter.value
    }
    
    public init(url: URL, options: JSONEncoder.OutputFormatting? = nil) {
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
            for await entry in asyncQueue {
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
    public func record<DependencyAction: Encodable>(to url: URL, options: JSONEncoder.OutputFormatting? = nil, modificationClosure: _RecordReducer<Self, DependencyAction>.ModificationClosure? = nil) -> _RecordReducer<Self, DependencyAction> {
        _RecordReducer(base: self, submitter: LogWriter<State, Action, DependencyAction>.init(url: url, options: options), modificationClosure: modificationClosure)
    }
    
    public func record<DependencyAction: Encodable>(with submitter: LogWriter<State, Action, DependencyAction>, modificationClosure: _RecordReducer<Self, DependencyAction>.ModificationClosure? = nil) -> _RecordReducer<Self, DependencyAction> {
        _RecordReducer(base: self, submitter: submitter, modificationClosure: modificationClosure)
    }
}

public struct _RecordReducer<Base: ReducerProtocol, DependencyAction: Encodable>: ReducerProtocol where Base.State: Encodable, Base.Action: Encodable {
  @usableFromInline
  let base: Base

  @usableFromInline
    let submitter: LogWriter<Base.State, Base.Action, DependencyAction>?
    
    public typealias ModificationClosure = (inout DependencyValues, @escaping (DependencyAction) -> ()) -> ()
    
    let modificationClosure: ModificationClosure?

  @usableFromInline
  init(base: Base, submitter: LogWriter<Base.State, Base.Action, DependencyAction>?, modificationClosure: ModificationClosure?) {
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
