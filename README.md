# TCATestRecording

See [my blog post](https://jackyoustra.com/blog/tca-test-recording) for a full description.

Record a description of the state, actions, and dependency usages of your reducer
and replay them in a test!

Record Usage:

```swift
let submitter = LogWriter<AppReducer.State, AppReducer.Action, DependencyAction>(url: logLocation)
AppReducer()
    .record(with: submitter) { values, recorder in
        values.withRandomNumberGenerator = .init(RecordedRNG(values.withRandomNumberGenerator, submission: { recording(.setRNG($0)) }))
        // stub other dependencies, especially ones used in your test
        // you can use ones out of the box in DependencyAction, or create your own enum
    }
    // Rest of dependencies
```

Playback usage:

```swift
let data = try ReplayRecordOf<AppReducer, DependencyAction>(url: logLocation)
data.test(AppReducer())
```
