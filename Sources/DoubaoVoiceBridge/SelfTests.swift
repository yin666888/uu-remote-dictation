import Foundation
import CoreGraphics
import AppKit

enum SelfTests {
    static func run() -> Bool {
        var failures: [String] = []

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: true)), [.suppress, .scheduleThreshold], "long hold down")
            check(state.phase, .pending, "long hold pending")
            check(state.handle(.thresholdReached), [.beginDictation], "long hold threshold")
            check(state.phase, .dictating, "long hold dictating")
            check(state.handle(.controlUp), [.suppress, .finishDictation], "long hold release")
            state.reset()
            check(state.phase, .idle, "long hold idle")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "chord recovery")
            check(state.phase, .passthrough, "chord passthrough")
            check(state.handle(.controlUp), [.passThrough], "chord release")
            check(state.phase, .idle, "chord idle")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: false)), [.passThrough], "non-UU down")
            check(state.phase, .idle, "non-UU idle")
            check(state.handle(.controlUp), [.passThrough], "non-UU release")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            for cycle in 1...3 {
                check(state.handle(.controlUp), [.suppress, .beginDictation], "tap starts cycle \(cycle)")
                check(state.phase, .latched, "tap stays listening after release")
                check(state.handle(.thresholdReached), [.suppress], "stale hold timer cannot restart tap mode")
                check(state.handle(.controlDown(targetAvailable: false)), [.suppress], "second tap works while local composer owns focus")
                check(state.phase, .finishingTap, "wait for physical release before sending")
                check(state.handle(.controlUp), [.suppress, .finishDictation], "second tap stops cycle \(cycle)")
                state.reset()
                check(state.phase, .idle, "tap cycle resets")
                _ = state.handle(.controlDown(targetAvailable: true))
            }
        }

        do {
            for stopping in [false, true] {
                var state = HoldGestureState()
                _ = state.handle(.controlDown(targetAvailable: true))
                _ = state.handle(.controlUp)
                if stopping { _ = state.handle(.controlDown(targetAvailable: false)) }
                check(state.handle(.otherInput), [.cancelDictation, .passThrough], "unrelated input cancels synthetic hold")
                check(state.phase, .idle, "cancel leaves no active gesture")
                _ = state.handle(.controlDown(targetAvailable: true))
                check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "Ctrl chord works after cancellation")
                _ = state.handle(.controlUp)
                _ = state.handle(.controlDown(targetAvailable: true))
                check(state.handle(.thresholdReached), [.beginDictation], "hold still works after tap cancellation")
            }
        }

        do {
            let flagsMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            let uu = InstalledEventTap(
                processIdentifier: 100,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            let bridge = InstalledEventTap(
                processIdentifier: 200,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [uu, bridge], bridgePID: 200, uuRemotePID: 100),
                true,
                "UU tap ahead requires reinstall"
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [bridge, uu], bridgePID: 200, uuRemotePID: 100),
                false,
                "bridge tap ahead stays installed"
            )
            let doubao = InstalledEventTap(processIdentifier: 300,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask, isEnabled: true)
            check(UURemoteTapOrder.needsReinstall(taps: [doubao, bridge], bridgePID: 200,
                uuRemotePID: 100, otherKeyboardPIDs: [300]), true,
                "Doubao reinstall between dictations must not swallow the next hold")
            check(UURemoteTapOrder.needsReinstall(taps: [bridge, doubao, uu], bridgePID: 200,
                uuRemotePID: 100, otherKeyboardPIDs: [300]), false,
                "repaired tap order does not trigger repeated reinstall")
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 100),
                0.25,
                "same-PID UU activation is audited"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 101),
                0.8,
                "new-PID UU launch gets settle time"
            )
        }

        do {
            check(
                SyntheticControlRoute.localHIDDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "local dictation reaches Doubao HID listener"
            )
            check(
                SyntheticControlRoute.remoteHIDPassthrough.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "remote Control chords stay on HID path"
            )
        }

        do {
            do {
                let events = try ClipboardKeyboardPaster.makeCommandVEvents()
                check(events.count, 4, "Command-V event count")
                check(
                    events.map(\.type),
                    [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                    "Command-V event types"
                )
                check(
                    events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                    [55, 9, 9, 55],
                    "Command-V event key codes"
                )
                check(events[0].flags.contains(.maskCommand), true, "Command down flag")
                check(
                    (events[0].flags.rawValue & 0x8) != 0,
                    true,
                    "left Command device flag"
                )
                check(events[1].flags, events[0].flags, "V down inherits Command state")
                check(events[2].flags, events[0].flags, "V up inherits Command state")
                check(events[3].flags.contains(.maskCommand), false, "Command up clears flag")
                check(
                    (events[3].flags.rawValue & 0x8) == 0,
                    true,
                    "Command up clears left device flag"
                )
                check(
                    events.allSatisfy {
                        $0.getIntegerValueField(.eventSourceUserData) ==
                            ControlHoldMonitor.syntheticEventMarker
                    },
                    true,
                    "Command-V events carry bridge marker"
                )
            } catch {
                failures.append("Command-V event creation: \(error)")
            }
        }

        do {
            check(PrivacySafeTextMetrics.lengthBucket(0), "empty", "empty length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(4), "1-4", "short length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(16), "5-16", "medium length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(64), "17-64", "long length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(65), "65+", "largest length bucket")
        }

        do {
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: true,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "empty transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.25,
                    stableFor: 0.20
                ),
                true,
                "settle at optimized thresholds"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: true,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "marked transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.24,
                    stableFor: 1.0
                ),
                false,
                "release grace is preserved"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 0.19
                ),
                false,
                "tail correction resets stable window"
            )
            check(
                UURemoteDelivery.defaultPasteDelay >= UURemoteDelivery.minimumPasteDelay,
                true,
                "default UU sync delay respects safety floor"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.9)),
                UURemoteDelivery.defaultPasteDelay,
                "numeric v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: "0.9"),
                UURemoteDelivery.defaultPasteDelay,
                "string v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.7)),
                nil,
                "custom delay is preserved"
            )
        }

        do {
            let scrollView = NSScrollView(frame: .zero)
            let textView = NSTextView()
            textView.textContainerInset = NSSize(width: 12, height: 10)
            ComposerTextLayout.attach(textView, to: scrollView)
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            ComposerTextLayout.synchronize(textView, with: scrollView)
            check(textView.frame.width > 0, true, "composer text view has drawable width")
            check(
                textView.frame.width,
                scrollView.contentSize.width,
                "composer text view tracks scroll width"
            )
            check(
                (textView.textContainer?.containerSize.width ?? 0) > 0,
                true,
                "composer text container has drawable width"
            )
            check(
                textView.textContainer?.widthTracksTextView,
                true,
                "composer container tracks text view width"
            )
        }

        do {
            let key = Data(repeating: 7, count: 32)
            let message = DirectInputMessage(operation: "commit", session: UUID(), text: "中文😀\n第二行")
            do {
                let wire = try DirectInputCodec.encode(message, key: key)
                var framer = DirectInputFramer()
                var frames: [Data] = []
                for byte in wire { frames += try framer.append(Data([byte])) }
                check(frames.count, 1, "fragmented encrypted frame")
                let decoded = try DirectInputCodec.decode(frames[0], key: key)
                check(decoded.text, message.text, "encrypted Chinese and emoji round trip")
                check(decoded.session, message.session, "session identity round trip")
                check(try framer.append(wire + wire).count, 2, "coalesced frames")
                var rejected = false
                do { _ = try DirectInputCodec.decode(frames[0], key: Data(repeating: 8, count: 32)) }
                catch { rejected = true }
                check(rejected, true, "wrong pairing key rejected")
                var corrupt = frames[0]
                corrupt[corrupt.count - 1] ^= 1
                rejected = false
                do { _ = try DirectInputCodec.decode(corrupt, key: key) }
                catch { rejected = true }
                check(rejected, true, "tampered ciphertext rejected")
            } catch { failures.append("direct input encryption: \(error)") }
        }
        do {
            for bytes: [UInt8] in [[0, 0, 0, 0], [255, 255, 255, 255]] {
                var rejected = false
                var framer = DirectInputFramer()
                do { _ = try framer.append(Data(bytes)) } catch { rejected = true }
                check(rejected, true, "invalid frame size rejected")
            }
            check(DirectInputCodec.key(from: String(repeating: "ab", count: 32))?.count, 32, "valid pairing key")
            check(DirectInputCodec.key(from: String(repeating: "zz", count: 32)), nil, "nonhex pairing key rejected")
            check(DirectInputCodec.key(from: "123"), nil, "short pairing key rejected")
        }
        do {
            let text = String(repeating: "中", count: 19) + "😀👨‍👩‍👧‍👦e\u{301}\n中文"
            let chunks = DirectUnicodeInput.chunks(text)
            check(chunks.allSatisfy { $0.count <= 20 }, true, "Unicode event size bounded")
            check(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text, "surrogate pairs preserved")
            do {
                let events = try DirectUnicodeInput.events(for: text)
                check(events.count, chunks.count, "one down/up pair per chunk")
                check(events.allSatisfy { $0.0.type == .keyDown && $0.1.type == .keyUp && $0.0.flags.isEmpty && $0.1.flags.isEmpty }, true, "direct text has no Command-V modifiers")
                var result = ""
                for pair in events {
                    var units = [UniChar](repeating: 0, count: 32)
                    var length = 0
                    pair.0.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                    result += String(decoding: units.prefix(length), as: UTF16.self)
                }
                check(result, text, "direct event payload preserves full text")
            } catch { failures.append("direct Unicode events: \(error)") }
        }

        failures += DoubaoShortcutTests.run()
        failures += InputFocusPreparationTests.run()
        failures += DirectInputStreamingTests.run()
        failures += DirectInputNetworkTests.run()
        failures += DirectInputReceiverTests.run()
        failures += ReceiverAutoStartTests.run()
        failures += UUSessionMonitorTests.run()
        failures += UUMappingHealthTests.run()

        if failures.isEmpty {
            print("SELF_TEST_OK groups=26")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }
}
