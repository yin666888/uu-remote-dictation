import Foundation
import os.log

// Registers the receiver as a per-user LaunchAgent so it comes back after a
// reboot. The agent only runs `/usr/bin/open` at login, so the app is started
// through LaunchServices and keeps its bundle identity for TCC permissions.
enum ReceiverAutoStart {
    static let label = "org.remotedictation.bridge.Receiver.autostart"
    private static let disabledDefaultsKey = "receiverAutoStartDisabled"
    private static let logger = Logger(subsystem: "org.remotedictation.bridge", category: "autostart")

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: disabledDefaultsKey)
            && FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func makePlist(appPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
    }

    static func installedAppPath() -> String? {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return appPath(fromPlist: plist)
    }

    static func appPath(fromPlist plist: [String: Any]) -> String? {
        guard let arguments = plist["ProgramArguments"] as? [String],
              arguments.count >= 3,
              arguments[0] == "/usr/bin/open",
              arguments[1] == "-a" else { return nil }
        return arguments[2]
    }

    static func prepareOnLaunch() {
        guard !UserDefaults.standard.bool(forKey: disabledDefaultsKey) else { return }
        let appPath = Bundle.main.bundleURL.path
        if installedAppPath() == appPath, FileManager.default.fileExists(atPath: launchAgentURL.path) {
            return
        }
        if !enable() {
            logger.error("Unable to install receiver auto-start agent")
        }
    }

    @discardableResult
    static func enable() -> Bool {
        let appPath = Bundle.main.bundleURL.path
        let plist = makePlist(appPath: appPath)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            logger.error("Unable to write auto-start agent: \(error.localizedDescription, privacy: .public)")
            return false
        }
        UserDefaults.standard.set(false, forKey: disabledDefaultsKey)
        reloadAgent()
        logger.notice("Receiver auto-start enabled for \(appPath, privacy: .public)")
        return true
    }

    static func disable() {
        UserDefaults.standard.set(true, forKey: disabledDefaultsKey)
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        logger.notice("Receiver auto-start disabled")
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            _ = enable()
        } else {
            disable()
        }
    }

    private static func reloadAgent() {
        let domain = "gui/\(getuid())"
        // Bootout first so an updated app path takes effect; the job only holds
        // a finished `open` process, so this never touches the running app.
        runLaunchctl(["bootout", "\(domain)/\(label)"])
        runLaunchctl(["bootstrap", domain, launchAgentURL.path])
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("launchctl \(arguments.first ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
