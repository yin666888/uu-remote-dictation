import AppKit

// Use UU's documented JSON interface, never window focus or a TCP listener as
// evidence of a desktop control session. Mapping-only connections are excluded
// by this interface (verified on UU 4.45.0).
enum UUSessionStatus {
    private struct Response: Decodable {
        let success: Bool
        let data: Payload?
    }
    private struct Payload: Decodable {
        let connections: [Connection]
    }
    private struct Connection: Decodable {
        let deviceId: String
        let connectionState: String
        let isControlling: Bool
    }

    static func isControlling(_ data: Data, targetID: String) -> Bool {
        guard !targetID.isEmpty, data.count <= 256 * 1024,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success, let connections = response.data?.connections else { return false }
        return connections.contains {
            $0.deviceId == targetID && $0.connectionState == "connected" && $0.isControlling
        }
    }
}

final class UUSessionMonitor {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var generation = UUID()
    private var polling = false
    private(set) var isControlling = false
    private let targetID: String
    private let cliURL: URL

    init(targetID: String,
         cliURL: URL = URL(fileURLWithPath: "/Applications/UURemote.app/Contents/Helpers/uuyc-cli")) {
        self.targetID = targetID
        self.cliURL = cliURL
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        polling = false
        publish(false)
    }

    private func publish(_ active: Bool) {
        guard active != isControlling else { return }
        isControlling = active
        onChange?(active)
    }

    private func poll() {
        guard !polling, !targetID.isEmpty else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.uuRemoteBundleIdentifier).isEmpty else {
            publish(false)
            return
        }
        polling = true
        let token = generation
        let targetID = targetID
        let cliURL = cliURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let active = Self.query(cliURL: cliURL, targetID: targetID)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.polling = false
                self.publish(active)
            }
        }
    }

    static func query(cliURL: URL, targetID: String) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = cliURL
        process.arguments = ["device", "status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        // Bound an unresponsive XPC request. No shell and no saved credentials.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let hardTimeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5, execute: hardTimeout)
        var data = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 256 * 1024 {
                if process.isRunning { process.terminate() }
                break
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        hardTimeout.cancel()
        return process.terminationStatus == 0 && UUSessionStatus.isControlling(data, targetID: targetID)
    }
}
