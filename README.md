# TCATestRecording

See [my blog post](https://jackyoustra.com/blog/tca-test-recording) for a full description.

Record a description of the state, actions, and dependency usages of your reducer
and replay them in a test!

Record Usage:

```
let submitter = await SharedThing<AppReducer.State, AppReducer.Action, DependencyAction>(url: logLocation)
AppReducer()
    .record(with: submitter) { values, recorder in
        values.withRandomNumberGenerator = .init(RecordedRNG(values.withRandomNumberGenerator, submission: { recording(.setRNG($0)) }))
    }
    // Rest of dependencies
```

Playback usage:

```
let data = try ReplayRecordOf<AppReducer, DependencyAction>(url: logLocation)
data.test(AppReducer())
```
