import Foundation

enum UUMappingHealthTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            if actual != expected { failures.append("mapping health: \(name)") }
        }
        let now = Date(timeIntervalSince1970: 1000)
        var health = UUMappingHealth()
        check(health.decision(processID: 10, at: now), .wait, "no observation cannot manipulate UI")
        for n in 0..<30 {
            let time = now.addingTimeInterval(Double(n))
            health.observe(true, processID: 10, at: time)
            check(health.decision(processID: 10, at: time), .healthy, "healthy tunnel never reopens an invisible window")
        }
        let later = now.addingTimeInterval(40)
        health.observe(false, processID: 10, at: later)
        check(health.decision(processID: 10, at: later), .wait, "one missing sample does not steal focus")
        health.observe(false, processID: 10, at: later.addingTimeInterval(1))
        check(health.decision(processID: 10, at: later.addingTimeInterval(1)), .recover, "confirmed closure permits recovery")
        check(health.decision(processID: 11, at: later.addingTimeInterval(1)), .wait, "new UU process rejects stale evidence")
        check(health.decision(processID: 10, at: later.addingTimeInterval(8)), .wait, "expired evidence cannot trigger recovery")
        health.observe(nil, processID: 10, at: later.addingTimeInterval(2))
        health.observe(false, processID: 10, at: later.addingTimeInterval(3))
        check(health.decision(processID: 10, at: later.addingTimeInterval(3)), .wait, "probe failure breaks the closed streak")
        health.observe(true, processID: 10, at: later.addingTimeInterval(4))
        check(health.decision(processID: 10, at: later.addingTimeInterval(4)), .healthy, "successful recovery stops UI operations")
        health.observe(false, processID: 10, at: later.addingTimeInterval(5))
        check(health.decision(processID: 10, at: later.addingTimeInterval(5)), .wait, "recovery clears old closed samples")
        check(UUMappingListenerProbe.parse(output: Data("p10\nn127.0.0.1:12345\n".utf8), exitStatus: 0, port: 12345), true, "exact loopback listener")
        check(UUMappingListenerProbe.parse(output: Data(), exitStatus: 1, port: 12345), false, "no socket")
        check(UUMappingListenerProbe.parse(output: Data("lsof: error".utf8), exitStatus: 1, port: 12345), nil, "error is unknown, not closed")
        check(UUMappingListenerProbe.parse(output: Data("p10\nn*:12345\n".utf8), exitStatus: 0, port: 12345), nil, "different bind address is not accepted")
        return failures
    }
}
