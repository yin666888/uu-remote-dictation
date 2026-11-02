import Foundation
import ApplicationServices
import zlib

enum DoubaoShortcutTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append(label) } }
        let control = VoiceShortcut(keyCode: 59, flags: 262145, display: "Ctrl")
        let rightControl = VoiceShortcut(keyCode: 62, flags: 262144 | 0x2000, display: "Ctrl")
        let chord = VoiceShortcut(keyCode: 49, flags: ShortcutEventFactory.modifierFlags([59,56]).rawValue, display: "Ctrl+Shift+Space")
        check(control.matches(key: 59, physicalModifiers: [59]), "left Ctrl matches")
        check(!control.matches(key: 62, physicalModifiers: [62]), "right Ctrl is not left Ctrl")
        check(rightControl.matches(key: 62, physicalModifiers: [62]), "right Ctrl matches")
        check(!control.matches(key: 59, physicalModifiers: [59,58]), "extra modifier preserves unrelated chord")
        check(chord.matches(key: 49, physicalModifiers: [59,56]), "ordinary key chord matches")
        check(!chord.matches(key: 49, physicalModifiers: [59]), "missing modifier does not match")
        check(!chord.matches(key: 49, physicalModifiers: [62,56]), "explicit left modifier side is honored")
        check(VoiceShortcut(keyCode:62,flags:262144,display:"Ctrl").requiredModifierCodes == [62], "side comes from primary modifier when device bits absent")

        // Reproduce the observed Fn tap sequence: release -> latched ->
        // hardware key 179 down/up. It must not cancel the latched session.
        var fnFilter = FnCompanionEventFilter()
        func companion(_ type: CGEventType, at time: TimeInterval, code: UInt16 = 179,
                       pid: Int64 = 0, marker: Int64 = 0) -> Bool {
            fnFilter.shouldSuppress(type: type, keyCode: code, sourcePID: pid, marker: marker, now: time)
        }
        check(!companion(.keyDown, at: 1), "uncaptured Fn companion passes through")
        fnFilter.arm(afterCapturedReleaseAt: 2)
        check(!companion(.keyDown, at: 2.01, code: 53), "real Escape still cancels")
        check(!companion(.keyDown, at: 2.01, code: 0), "ordinary typing still cancels")
        check(!companion(.keyDown, at: 2.01, pid: 817), "unrelated software event is not filtered")
        check(!companion(.keyDown, at: 2.01, marker: 1), "marked software event is not filtered")
        var fnGesture = HoldGestureState()
        _ = fnGesture.handle(.controlDown(targetAvailable: true))
        _ = fnGesture.handle(.controlUp)
        if !companion(.keyDown, at: 2.05) { _ = fnGesture.handle(.otherInput) }
        check(fnGesture.phase == .latched, "Fn companion cannot cancel tap-started listening")
        check(companion(.keyUp, at: 2.07), "matching companion release is consumed")
        check(!companion(.keyDown, at: 2.08), "only one companion pair per captured Fn release")
        _ = fnGesture.handle(.controlDown(targetAvailable: false))
        let end = fnGesture.handle(.controlUp)
        check(end.contains(.finishDictation), "second Fn tap still finishes listening")
        fnGesture.reset()
        fnFilter.arm(afterCapturedReleaseAt: 3)
        check(companion(.keyDown, at: 3.01) && companion(.keyUp, at: 3.02), "ending companion is consumed after gesture reset")
        fnFilter.arm(afterCapturedReleaseAt: 4)
        check(!companion(.keyDown, at: 4.31), "late key 179 is not silently swallowed")
        fnFilter.arm(afterCapturedReleaseAt: 5)
        check(!companion(.keyUp, at: 5.01), "unmatched key-up passes through")
        check(companion(.keyDown, at: 5.02), "unmatched up does not consume allowance")
        check(!companion(.keyUp, at: 5.53), "companion release allowance expires")

        for shortcut in [control,rightControl,chord,VoiceShortcut(keyCode:63,flags:CGEventFlags.maskSecondaryFn.rawValue,display:"Fn"),VoiceShortcut(keyCode:96,flags:0,display:"F5")] {
            let down = ShortcutEventFactory.events(for: shortcut, down: true)
            let up = ShortcutEventFactory.events(for: shortcut, down: false)
            check(!down.isEmpty && down.count == up.count, "balanced synthetic shortcut \(shortcut.display)")
            check((down + up).allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == ControlHoldMonitor.syntheticEventMarker }, "synthetic events cannot retrigger monitor")
            check(up.last?.flags.intersection(VoiceShortcut.logicalMask).isEmpty == true, "shortcut release clears all synthetic modifiers")
            check(down.map { $0.getIntegerValueField(.keyboardEventKeycode) } == up.reversed().map { $0.getIntegerValueField(.keyboardEventKeycode) }, "reverse release order")
        }
        check(ShortcutEventFactory.events(for: chord, down: true).map(\.type) == [.flagsChanged,.flagsChanged,.keyDown], "chord presses modifiers before main key")
        check(ShortcutEventFactory.events(for: chord, down: false).map(\.type) == [.keyUp,.flagsChanged,.flagsChanged], "chord releases main key before modifiers")
        let settings: [String:Any] = ["asrLongPressShortcutKeyCode":59,"asrLongPressShortcutModifierFlags":262145,"asrLongPressShortcutKeyDisplay":"Ctrl", "asrShortcutKeyCode":49,"asrShortcutModifierFlags":chord.flags,"asrShortcutKeyDisplay":"Ctrl+Shift+Space"]
        do {
            let config = try DoubaoShortcutConfiguration.decode(settings)
            check(config.hold == control && config.tap == chord, "hold and tap settings remain distinct")
            var fnSettings = settings
            for prefix in ["asrLongPressShortcut", "asrShortcut"] {
                fnSettings[prefix + "KeyCode"] = 63
                fnSettings[prefix + "ModifierFlags"] = 0
                fnSettings[prefix + "KeyDisplay"] = "fn"
            }
            let fnConfig = try DoubaoShortcutConfiguration.decode(fnSettings)
            let fn = try XCTUnwrapShortcut(fnConfig.hold)
            check(fnConfig.tap == fn, "both modes decode Doubao's actual zero-flag Fn settings")
            check(fn.matches(key: 63, physicalModifiers: [63]), "normalized Fn matches physical press")
            check(!fn.matches(key: 63, physicalModifiers: [63,59]), "Fn plus extra modifier does not match")
            let fnDown = ShortcutEventFactory.events(for: fn, down: true)
            let fnUp = ShortcutEventFactory.events(for: fn, down: false)
            check(fnDown.count == 1 && fnDown.first?.type == .flagsChanged && fnDown.first?.flags.contains(.maskSecondaryFn) == true, "decoded Fn replays Fn down")
            check(fnUp.count == 1 && fnUp.first?.type == .flagsChanged && fnUp.first?.flags.contains(.maskSecondaryFn) == false, "decoded Fn replays Fn up")
            fnSettings["asrLongPressShortcutModifierFlags"] = CGEventFlags.maskSecondaryFn.rawValue
            check(try DoubaoShortcutConfiguration.decode(fnSettings) == fnConfig, "explicit and implicit Fn flags normalize equally")
            var incompleteControl = settings
            incompleteControl["asrLongPressShortcutModifierFlags"] = 0
            check((try? DoubaoShortcutConfiguration.decode(incompleteControl)) == nil, "Fn exception does not accept incomplete Ctrl")
            var changed = settings
            changed["asrLongPressShortcutKeyCode"] = -1
            let disabled = try DoubaoShortcutConfiguration.decode(changed)
            check(disabled.hold == nil && disabled.tap == chord, "cleared shortcut stays disabled instead of falling back")
            changed["asrShortcutKeyCode"] = 57
            check((try? DoubaoShortcutConfiguration.decode(changed)) == nil, "unsupported toggle key is explicit")
            check((try? DoubaoShortcutConfiguration.decode([:])) == nil, "missing format never guesses Ctrl")

            let archive = try NSKeyedArchiver.archivedData(withRootObject: settings, requiringSecureCoding: true)
            check(try DoubaoShortcutSettings.decodeArchive(archive) == config, "safe keyed-archive decoder")
            func varint(_ number: Int) -> Data {
                var value = number, result = Data()
                repeat { let byte = value & 127; value >>= 7; result.append(UInt8(byte | (value > 0 ? 128 : 0))) } while value > 0
                return result
            }
            func blob(_ data: Data) -> Data { varint(data.count) + data }
            func wrap(_ body: Data) -> (Data,Data) {
                func bytes(_ number: UInt32) -> Data { var value = number.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
                let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to:Bytef.self).baseAddress, uInt(body.count)) }
                var metadata = Data(repeating:0,count:40)
                metadata.replaceSubrange(0..<4,with:bytes(UInt32(crc)))
                metadata.replaceSubrange(4..<8,with:bytes(4))
                metadata.replaceSubrange(28..<32,with:bytes(UInt32(body.count)))
                return (bytes(UInt32(body.count)) + body, metadata)
            }
            let old = try NSKeyedArchiver.archivedData(withRootObject:["asrShortcutKeyCode":62],requiringSecureCoding:true)
            let record = blob(Data("d".utf8)) + blob(archive)
            let body = varint(0) + blob(Data("d".utf8)) + blob(old) + record
            var (data,metadata) = wrap(body)
            data.append(blob(Data("d".utf8)) + blob(old)) // stale storage beyond active size
            let latest = try DoubaoShortcutSettings.settingsRecord(data:data,metadata:metadata)
            check(latest == archive, "latest committed settings win; stale tail ignored")
            data[10] ^= 1
            check((try? DoubaoShortcutSettings.settingsRecord(data:data,metadata:metadata)) == nil, "partial or corrupted write rejected")
            let (deleted,deletedCRC) = wrap(body + blob(Data("d".utf8)) + blob(Data()))
            check((try? DoubaoShortcutSettings.settingsRecord(data:deleted,metadata:deletedCRC)) == nil, "deleted current setting never resurrects an old record")
            metadata[4] = 99
            check((try? DoubaoShortcutSettings.settingsRecord(data:data,metadata:metadata)) == nil, "unknown storage version rejected")
        } catch { failures.append("shortcut settings test: \(error)") }
        return failures
    }

    private static func XCTUnwrapShortcut(_ value: VoiceShortcut?) throws -> VoiceShortcut {
        guard let value else { throw DirectInputError.message("Fn setting unexpectedly disabled") }
        return value
    }
}
