import Foundation

enum UUSessionMonitorTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ json: String, _ expected: Bool, _ name: String, target: String = "target-a") {
            if UUSessionStatus.isControlling(Data(json.utf8), targetID: target) != expected {
                failures.append("UU desktop session: \(name)")
            }
        }
        let active = #"{"success":true,"data":{"connections":[{"deviceId":"target-a","connectionState":"connected","isControlling":true}]}}"#
        check(active, true, "exact connected controller")
        check(active, false, "different target", target: "target-b")
        check(active, false, "empty target", target: "")
        check(active.replacingOccurrences(of: "connected", with: "connecting"), false, "still connecting")
        check(active.replacingOccurrences(of: "connected", with: "disconnected"), false, "disconnected")
        check(active.replacingOccurrences(of: #""isControlling":true"#, with: #""isControlling":false"#), false, "view-only session")
        check(active.replacingOccurrences(of: #""success":true"#, with: #""success":false"#), false, "failed response")
        check(#"{"success":true,"data":{"connections":[]}}"#, false, "mapping alone / no desktop")
        check(#"{"success":true,"data":{"connections":[{"deviceId":"target-a","connectionState":"connected"}]}}"#, false, "missing control flag")
        check(#"{"success":true,"data":null}"#, false, "missing payload")
        check("not JSON", false, "malformed response")
        return failures
    }
}
