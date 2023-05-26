// AUTOGENERATED FILE

import ComposableArchitecture
import XCTest
import TestRecording
@testable import TestRecordingTests

@available(macOS 13.0, *)
class AppReducerTests: XCTestCase {

    func testRecording() throws {
        let logURL = URL(string: "file:///var/folders/lh/_v9mhxf13_g0qwyqgj0m8l2m0000gn/T/test.log")!
        let decoding = try ReplayRecord<AppReducer.State, AppReducer.Action, TestRecordingTests.DependencyAction>.init(url: logURL)
        let store = TestStore(
            initialState: decoding.start,
            reducer: AppReducer()
        )

        let quantum0 = decoding.replayActions[0].asQuantum!
        store.send(quantum0.action) {
          $0 = quantum0.result
        }
        
        // store.dependencies = {"setRNG":{"_0":0}}"
        decoding.replayActions[1].asDependencySet!.resetDependency(on: &store.dependencies)
        
        let quantum2 = decoding.replayActions[2].asQuantum!
        store.send(quantum2.action) {
          $0 = quantum2.result
        }
        
        // store.dependencies = {"setRNG":{"_0":1}}"
        decoding.replayActions[3].asDependencySet!.resetDependency(on: &store.dependencies)
        
        let quantum4 = decoding.replayActions[4].asQuantum!
        store.send(quantum4.action) {
          $0 = quantum4.result
        }
        
        // store.dependencies = {"setRNG":{"_0":2}}"
        decoding.replayActions[5].asDependencySet!.resetDependency(on: &store.dependencies)
        
        let quantum6 = decoding.replayActions[6].asQuantum!
        store.send(quantum6.action) {
          $0 = quantum6.result
        }
        
        
    }
}