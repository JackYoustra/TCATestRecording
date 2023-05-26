import ComposableArchitecture

struct SequentialRNG: RandomNumberGenerator {
    var count = UInt64(0)
    mutating func next() -> UInt64 {
        defer { count += 1 }
        return count
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

func singleAccess<T>(_ t: T) -> @Sendable () -> T {
    let hasBeenAccessed = LockIsolated(false)
    return {
        hasBeenAccessed.withValue {
            if $0 {
                XCTFail("singleAccess called more than once")
            }
            $0 = true
        }
        return t
    }
}

import Foundation

public enum DependencyAction: Codable, Equatable, DependencyOneUseSetting {
    case setRNG(UInt64)
    case setUUID(UUID)

    public func resetDependency(on deps: inout Dependencies.DependencyValues) {
        switch self {
        case let .setRNG(rn):
            deps.withRandomNumberGenerator = .init(SingleRNG(n: rn))
        case let .setUUID(uuid):
            deps.uuid = .init(singleAccess(uuid))
        }
    }
}

public extension ReducerProtocol where State: Encodable, Action: Encodable {
    func record(with submitter: LogWriter<State, Action, DependencyAction>) -> _RecordReducer<Self, DependencyAction> {
        self.record(with: submitter) { values, changeMission in
            values.withRandomNumberGenerator = .init(RecordedRNG(values.withRandomNumberGenerator, submission: { changeMission(.setRNG($0)) }))
            let prior = values.uuid
            values.uuid = .init {
                let uuid = prior()
                changeMission(.setUUID(uuid))
                return uuid
            }
        }
    }
}
