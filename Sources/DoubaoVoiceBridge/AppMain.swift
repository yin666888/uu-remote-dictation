import AppKit

@main
enum DoubaoVoiceBridgeMain {
    static func main() {
        if CommandLine.arguments.contains("--check-mapping-listener") {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.uuRemoteBundleIdentifier).first else {
                print("MAPPING_LISTENER_ABSENT")
                exit(EXIT_FAILURE)
            }
            switch UUMappingListenerProbe.query(processID: app.processIdentifier, port: DirectInputSettings.port) {
            case true?: print("MAPPING_LISTENER_READY")
            case false?: print("MAPPING_LISTENER_ABSENT"); exit(EXIT_FAILURE)
            case nil: print("MAPPING_LISTENER_UNKNOWN"); exit(2)
            }
            return
        }
        if CommandLine.arguments.contains("--check-input-target") {
            DirectInputFocus.printTargetReport()
            return
        }
        if CommandLine.arguments.contains("--prepare-input-target") {
            var finished = false
            DirectInputFocus.capture { result in
                switch result {
                case .success(let target): print("INPUT_TARGET_READY preview=\(target.supportsPreview)")
                case .failure(let error): print("INPUT_TARGET_FAILED: \(error.localizedDescription)")
                }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return
        }
        if CommandLine.arguments.contains("--check-shortcuts") {
            do { print(try DoubaoShortcutSettings.read().status) }
            catch { print("SHORTCUT_READ_FAILED: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
            return
        }
        if CommandLine.arguments.contains("--diagnostics") {
            Diagnostics.printReport()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTests.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--check-connection") {
            exit(Diagnostics.checkDirectInputConnection() ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
