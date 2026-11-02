import Foundation

enum ReceiverAutoStartTests {
    static func run() -> [String] {
        var failures: [String] = []

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        let appPath = "/Applications/远控直输接收端.app"
        let plist = ReceiverAutoStart.makePlist(appPath: appPath)
        check(plist["Label"] as? String, ReceiverAutoStart.label, "auto-start label")
        check(plist["ProgramArguments"] as? [String], ["/usr/bin/open", "-a", appPath], "auto-start launches through LaunchServices")
        check(plist["RunAtLoad"] as? Bool, true, "auto-start runs at login")
        check(plist["LimitLoadToSessionType"] as? String, "Aqua", "auto-start stays in the GUI session")
        check(ReceiverAutoStart.appPath(fromPlist: plist), appPath, "auto-start path round trip")

        check(ReceiverAutoStart.appPath(fromPlist: [:]), nil, "plist without arguments rejected")
        check(
            ReceiverAutoStart.appPath(fromPlist: ["ProgramArguments": ["/bin/sh", "-c", appPath]]),
            nil,
            "plist launching the binary directly rejected"
        )
        check(
            ReceiverAutoStart.appPath(fromPlist: ["ProgramArguments": ["/usr/bin/open", "-a"]]),
            nil,
            "plist without app path rejected"
        )

        return failures
    }
}
