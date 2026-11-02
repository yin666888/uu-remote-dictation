import Foundation

// A hidden or temporarily unreadable mapping window is not a broken tunnel.
// Only process-owned listener evidence may authorize starting UI recovery.
struct UUMappingHealth {
    enum Decision: Equatable { case wait, healthy, recover }
    private var processID: pid_t?
    private var observedAt = Date.distantPast
    private var consecutiveClosed = 0
    private var listening: Bool?

    mutating func observe(_ value: Bool?, processID: pid_t, at date: Date) {
        if self.processID != processID { consecutiveClosed = 0 }
        self.processID = processID
        observedAt = date
        listening = value
        if value == false { consecutiveClosed += 1 } else { consecutiveClosed = 0 }
    }

    func decision(processID: pid_t, at date: Date) -> Decision {
        guard self.processID == processID, date.timeIntervalSince(observedAt) >= 0,
              date.timeIntervalSince(observedAt) < 4 else { return .wait }
        if listening == true { return .healthy }
        return listening == false && consecutiveClosed >= 2 ? .recover : .wait
    }
}

enum UUMappingListenerProbe {
    static func parse(output: Data, exitStatus: Int32, port: UInt16) -> Bool? {
        guard port > 0, let text = String(data: output, encoding: .utf8) else { return nil }
        // lsof returns 1 with no output for no matching socket. Other errors,
        // including unexpected addresses/output, must not trigger UI actions.
        if exitStatus == 1 && text.isEmpty { return false }
        guard exitStatus == 0 else { return nil }
        return text.split(separator: "\n").contains(Substring("n127.0.0.1:\(port)")) ? true : nil
    }

    static func query(processID: pid_t, port: UInt16) -> Bool? {
        guard processID > 0, port > 0 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(processID), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        process.standardOutput = output
        // Include diagnostic output in the parse input, so an error with exit
        // status 1 cannot look like a successful 'no matching socket' result.
        process.standardError = output
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let hardTimeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: hardTimeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        hardTimeout.cancel()
        return parse(output: data, exitStatus: process.terminationStatus, port: port)
    }
}
