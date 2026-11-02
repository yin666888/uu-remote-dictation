import Foundation

enum InputFocusPreparationTests {
    static func run() -> [String] {
        var failures: [String] = []
        for scenario in ["alreadyReady", "delayedTree", "unsupported", "changed", "timeout"] {
            var reads = 0, prepares = 0, callbacks = 0
            var current = true
            var result: Result<String, Error>?
            InputFocusPreparation.capture(isCurrent: { current }, read: {
                reads += 1
                if scenario == "alreadyReady" || (scenario == "delayedTree" && reads == 3) { return "target" }
                throw DirectInputError.message("not editable yet")
            }, prepare: {
                prepares += 1
                if scenario == "changed" { current = false }
                return scenario != "unsupported"
            }, retryCount: 3, interval: 0.001) {
                callbacks += 1
                result = $0
            }
            let deadline = Date().addingTimeInterval(1)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            if callbacks != 1 { failures.append("focus preparation completion count: \(scenario)") }
            let succeeds = (try? result?.get()) == "target"
            if succeeds != (scenario == "alreadyReady" || scenario == "delayedTree") {
                failures.append("focus preparation result: \(scenario)")
            }
            if scenario == "alreadyReady" && (reads != 1 || prepares != 0) { failures.append("ready input unnecessarily prepared") }
            if scenario == "unsupported" && reads != 1 { failures.append("unsupported input repeatedly polled") }
            if scenario == "changed" && reads != 1 { failures.append("new target read after focus changed") }
            if scenario == "timeout" && reads != 4 { failures.append("focus retries not bounded") }
        }
        return failures
    }
}
