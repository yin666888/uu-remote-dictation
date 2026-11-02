import Foundation
import AppKit

enum DirectInputStreamingTests {
    private final class Destination: DirectInputDestination {
        var supportsPreview = true
        var document = "前😀选中后"
        var selection = NSRange(location: 3, length: 2)
        var model = try! DirectInputReplacement(original: "前😀选中后", selection: NSRange(location: 3, length: 2))
        var previews: [String] = []
        var commits = 0
        var cancellations = 0
        func updatePreview(_ text: String) throws {
            try model.validate(value: document, selection: selection)
            model.didWrite(text)
            document = model.expectedValue
            selection = model.selection
            previews.append(text)
        }
        func insert(_ text: String, isActive: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
            guard isActive() else { completion(.failure(DirectInputError.message("inactive"))); return }
            do { try updatePreview(text); commits += 1; completion(.success(())) }
            catch { completion(.failure(error)) }
        }
        func cancelPreview() {
            guard model.preview != nil,
                  (try? model.validate(value: document, selection: selection)) != nil else { return }
            document = model.original
            selection = model.originalRange
            cancellations += 1
        }
    }
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ good: Bool, _ message: String) { if !good { failures.append(message) } }
        let missing = NSRange(location: NSNotFound, length: 0)
        check(TranscriptDraftSnapshot.replacing("前你好后", markedRange: NSRange(location: 1, length: 2), selectedRange: NSRange(location: 3, length: 0), replacementRange: missing, with: "你们好😀") == "前你们好😀后", "IME marked text replaces its previous draft")
        check(TranscriptDraftSnapshot.replacing("前后", markedRange: missing, selectedRange: NSRange(location: 1, length: 0), replacementRange: missing, with: "中") == "前中后", "IME initial draft uses caret")
        check(TranscriptDraftSnapshot.replacing("😀", markedRange: missing, selectedRange: NSRange(location: 1, length: 0), replacementRange: missing, with: "中") == nil, "IME snapshot rejects split surrogate")
        let textView = ComposerTextView()
        var snapshots: [(String, Bool)] = []
        textView.onDraftChanged = { snapshots.append(($0, $1)) }
        textView.setMarkedText("明天去", selectedRange: NSRange(location: 3, length: 0), replacementRange: missing)
        textView.setMarkedText("明天七点😀", selectedRange: NSRange(location: 6, length: 0), replacementRange: missing)
        textView.insertText("明天七点。", replacementRange: missing)
        check(snapshots.map { $0.0 } == ["明天去", "明天七点😀", "明天七点。"], "real composer captures corrections before commit")
        check(snapshots.map { $0.1 } == [true, true, false], "real composer distinguishes draft and final")
        check(textView.string == "明天七点。", "capturing drafts preserves local final text")

        do {
            var model = try DirectInputReplacement(original: "前😀选中后", selection: NSRange(location: 3, length: 2))
            try model.validate(value: "前😀选中后", selection: NSRange(location: 3, length: 2))
            model.didWrite("识别😀")
            check(model.expectedValue == "前😀识别😀后", "replacement preserves both surrounding sides")
            check(model.range == NSRange(location: 3, length: 4), "replacement uses UTF16 ranges")
            model.didWrite("纠正")
            check(model.expectedValue == "前😀纠正后", "shorter correction removes old tail")
            check((try? model.validate(value: model.expectedValue, selection: NSRange(location: 0, length: 0))) == nil, "moved caret stops replacement")
            check((try? model.validate(value: "用户修改", selection: model.selection)) == nil, "external edit stops replacement")
            check(model.originalSelectionText == "选中", "cancel can restore original selection")
        } catch { failures.append("replacement model: \(error)") }

        func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        for mode in ["commit", "cancel", "external-edit", "legacy"] {
            let key = Data(repeating: 37, count: 32)
            let destination = Destination()
            destination.supportsPreview = mode != "legacy"
            let receiver = DirectInputReceiver(keyProvider: { key }, portProvider: { 0 }, focusProvider: { destination })
            do { try receiver.start() }
            catch { failures.append("stream receiver: \(error)"); continue }
            pump(until: { receiver.listeningPort != nil })
            guard let port = receiver.listeningPort else { failures.append("stream receiver timed out"); receiver.stop(); continue }
            let sender = DirectInputClient(keyProvider: { key }, portProvider: { port })
            defer { sender.cancel(); receiver.stop() }
            var ready = false
            var failure: Error?
            sender.onSessionFailure = { failure = $0 }
            sender.begin { result in
                if case .success = result { ready = true }
                if case .failure(let error) = result { failure = error }
            }
            pump(until: { ready || failure != nil })
            check(ready, "stream handshake \(mode)")
            check(sender.supportsPreview == destination.supportsPreview, "preview capability negotiated \(mode)")
            sender.updatePreview("明天去")
            if mode != "legacy" {
                pump(until: { !destination.previews.isEmpty || failure != nil })
                check(destination.document == "前😀明天去后", "preview visible before final \(mode)")
            }
            if mode == "cancel" {
                sender.cancel()
                pump(until: { destination.cancellations > 0 })
                check(destination.document == "前😀选中后" && destination.selection == NSRange(location: 3, length: 2), "cancel restores only dictation selection")
            } else if mode == "external-edit" {
                destination.document = "用户修改"
                sender.updatePreview("不能覆盖用户修改")
                pump(until: { failure != nil })
                check(failure != nil, "preview conflict reaches sender")
                check(destination.document == "用户修改", "conflict never overwrites external edits")
                check(destination.commits == 0, "conflict never commits")
            } else {
                if mode != "legacy" {
                    sender.updatePreview("中间结果一")
                    sender.updatePreview("中间结果二")
                    sender.updatePreview("明天七点😀")
                    pump(until: { destination.previews.last == "明天七点😀" || failure != nil })
                    check(!destination.previews.contains("中间结果一") && !destination.previews.contains("中间结果二"), "rapid updates coalesce")
                }
                var finished = false
                sender.commit(text: "明天七点。") { result in
                    if case .failure(let error) = result { failure = error }
                    finished = true
                }
                pump(until: { finished || failure != nil })
                check(finished && failure == nil, "stream final accepted \(mode)")
                check(destination.document == "前😀明天七点。后", "final corrects draft without duplication \(mode)")
                check(destination.commits == 1, "exactly one commit \(mode)")
                if mode == "legacy" { check(destination.previews == ["明天七点。"], "unsupported target receives final only") }
            }
        }
        return failures
    }
}
