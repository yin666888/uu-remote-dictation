import Foundation
import Network

enum DirectInputReceiverTests {
    private final class Destination: DirectInputDestination {
        var writes: [String] = []
        func insert(_ text: String, isActive: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
            guard isActive() else { completion(.failure(DirectInputError.message("inactive"))); return }
            writes.append(text)
            completion(.success(()))
        }
    }

    // Exercise the production receiver, including its reply lifetime. The raw
    // client deliberately waits before reading the final reply, as a relay may.
    // The injected destination records text without touching any application.
    static func run() -> [String] {
        var failures: [String] = []
        for rejectFocus in [false, true] {
            let key = Data(repeating: 29, count: 32)
            let destination = Destination()
            let receiver = DirectInputReceiver(keyProvider: { key }, portProvider: { 0 }, focusProvider: {
                if rejectFocus { throw DirectInputError.message("test focus denied") }
                return destination
            })
            do { try receiver.start() }
            catch { failures.append("receiver start: \(error)"); continue }
            var connection: NWConnection?
            defer { connection?.cancel(); receiver.stop() }
            let deadline = Date().addingTimeInterval(4)
            while receiver.listeningPort == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let port = receiver.listeningPort else { failures.append("receiver listen timeout"); continue }
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection = client
            var framer = DirectInputFramer()
            var finished = false
            var phase = "hello"
            var session: UUID?
            func fail(_ description: String) { failures.append(description); finished = true }
            func send(_ message: DirectInputMessage) {
                do {
                    client.send(content: try DirectInputCodec.encode(message, key: key), completion: .contentProcessed { error in
                        if let error { fail("receiver test send: \(error)") }
                    })
                } catch { fail("receiver test encode: \(error)") }
            }
            func receive() {
                guard !finished else { return }
                client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
                    var deferReading = false
                    do {
                        for frame in try framer.append(data ?? Data()) {
                            let message = try DirectInputCodec.decode(frame, key: key)
                            if phase == "hello", message.operation == "hello" {
                                session = message.session
                                phase = rejectFocus ? "error" : "ready"
                                send(DirectInputMessage(operation: "begin", session: message.session))
                                if rejectFocus { deferReading = true }
                            } else if message.session == session, phase == "ready", message.operation == "ready" {
                                phase = "accepted"
                                send(DirectInputMessage(operation: "commit", session: message.session, text: "收件回执😀"))
                                deferReading = true
                            } else if message.session == session, phase == "accepted", message.operation == "accepted", message.error == nil {
                                finished = true
                            } else if message.session == session, phase == "error", message.operation == "error", message.error == "test focus denied" {
                                finished = true
                            } else { fail("receiver reply was out of sequence: \(message.operation)") }
                        }
                    } catch { fail("receiver test decode: \(error)") }
                    if finished { return }
                    if let error { fail("receiver closed before receipt: \(error)"); return }
                    if complete { fail("receiver ended before receipt"); return }
                    if deferReading {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { receive() }
                    } else { receive() }
                }
            }
            client.stateUpdateHandler = { state in
                if case .ready = state { receive() }
                if case .failed(let error) = state { fail("receiver test connection: \(error)") }
            }
            client.start(queue: .main)
            while !finished && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if !finished { failures.append("receiver receipt timeout phase=\(phase) port=\(port)") }
            if destination.writes != (rejectFocus ? [] : ["收件回执😀"]) {
                failures.append("receiver lost, duplicated, or unexpectedly wrote text")
            }
            client.stateUpdateHandler = nil
        }
        return failures
    }
}
