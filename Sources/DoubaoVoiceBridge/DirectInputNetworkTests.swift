import Foundation
import Network

enum DirectInputNetworkTests {
    // Loopback-only fake receiver: exercises the real transport without
    // permissions, Keychain writes, clipboard access, or posting input events.
    static func run() -> [String] {
        var failures: [String] = []
        for invalidReply in [false, true] {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                let key = Data(repeating: 11, count: 32)
                let challenge = UUID()
                var serverChannel: DirectInputChannel?
                var client: DirectInputClient?
                var finished = false
                var received = ""
                var operations: [String] = []
                listener.newConnectionHandler = { connection in
                    let channel = DirectInputChannel(connection: connection, key: key)
                    serverChannel = channel
                    channel.onReady = { [weak channel] in
                        channel?.send(DirectInputMessage(operation: "hello", session: challenge))
                    }
                    channel.onMessage = { [weak channel] message in
                        operations.append(message.operation)
                        guard message.session == challenge else {
                            failures.append("network: wrong session challenge")
                            finished = true
                            return
                        }
                        if message.operation == "begin" {
                            channel?.send(DirectInputMessage(operation: invalidReply ? "accepted" : "ready", session: challenge))
                        } else if message.operation == "commit" {
                            received = message.text ?? ""
                            channel?.send(DirectInputMessage(operation: "accepted", session: challenge))
                        }
                    }
                    channel.start()
                }
                listener.stateUpdateHandler = { state in
                    if case .ready = state, let port = listener.port {
                        let sender = DirectInputClient(keyProvider: { key }, portProvider: { port.rawValue })
                        client = sender
                        sender.begin { result in
                            switch result {
                            case .failure(let error):
                                if !invalidReply { failures.append("network begin: \(error)") }
                                finished = true
                            case .success:
                                if invalidReply {
                                    failures.append("network: accepted out-of-order response")
                                    finished = true
                                    return
                                }
                                sender.commit(text: "直输回环测试😀") { result in
                                    if case .failure(let error) = result { failures.append("network commit: \(error)") }
                                    finished = true
                                }
                            }
                        }
                    } else if case .failed(let error) = state {
                        failures.append("network listener: \(error)")
                        finished = true
                    }
                }
                listener.start(queue: .main)
                let deadline = Date().addingTimeInterval(3)
                while !finished && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                if !finished { failures.append("network round trip timed out") }
                if !invalidReply && (received != "直输回环测试😀" || operations != ["begin", "commit"]) {
                    failures.append("network round trip lost or duplicated text")
                }
                client?.cancel()
                serverChannel?.close()
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
            } catch { failures.append("network test: \(error)") }
        }
        return failures
    }
}
