import AppKit
import ApplicationServices
import zlib

struct VoiceShortcut: Equatable {
    static let logicalMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
    static let modifierFlags: [UInt16: CGEventFlags] = [54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift, 58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn]
    let keyCode: UInt16
    let flags: UInt64
    let display: String
    var isModifier: Bool { Self.modifierFlags[keyCode] != nil }
    var logicalFlags: CGEventFlags { CGEventFlags(rawValue: flags).intersection(Self.logicalMask) }
    var requiredModifierCodes: [UInt16] {
        // Device-specific bits distinguish left/right when Doubao stores them.
        let pairs: [(CGEventFlags, UInt16, UInt16, UInt64, UInt64)] = [
            (.maskControl, 59, 62, 0x1, 0x2000), (.maskShift, 56, 60, 0x2, 0x4),
            (.maskAlternate, 58, 61, 0x20, 0x40), (.maskCommand, 55, 54, 0x8, 0x10)]
        var result: [UInt16] = []
        for (mask, left, right, leftBit, rightBit) in pairs where logicalFlags.contains(mask) {
            if flags & (leftBit | rightBit) == 0, Self.modifierFlags[keyCode] == mask {
                result.append(keyCode)
            } else {
                if flags & rightBit != 0 { result.append(right) }
                if flags & leftBit != 0 || flags & (leftBit | rightBit) == 0 { result.append(left) }
            }
        }
        if logicalFlags.contains(.maskSecondaryFn) { result.append(63) }
        if isModifier && !result.contains(keyCode) { result.append(keyCode) }
        return result.filter { $0 != keyCode } + (isModifier ? [keyCode] : [])
    }
    func matches(key: UInt16, physicalModifiers: Set<UInt16>) -> Bool {
        guard key == keyCode else { return false }
        let physical = physicalModifiers.reduce(CGEventFlags()) { $0.union(Self.modifierFlags[$1] ?? []) }
        guard physical.intersection(Self.logicalMask) == logicalFlags else { return false }
        // For modifier-only shortcuts the key itself determines its side. For
        // chords honor side bits when they are explicitly present in settings.
        let sidePairs: [(UInt64, UInt16)] = [(1,59),(0x2000,62),(2,56),(4,60),(0x20,58),(0x40,61),(8,55),(0x10,54)]
        return sidePairs.allSatisfy { bit, code in flags & bit == 0 || physicalModifiers.contains(code) }
    }
}

struct DoubaoShortcutConfiguration: Equatable {
    let hold: VoiceShortcut?
    let tap: VoiceShortcut?
    var status: String {
        if hold == nil && tap == nil { return "豆包未设置语音快捷键，请先在豆包中设置" }
        return "跟随豆包 · 长按：\(hold?.display ?? "未设置") · 免按：\(tap?.display ?? "未设置")"
    }
    static func decode(_ settings: [String: Any]) throws -> Self {
        func shortcut(_ prefix: String) throws -> VoiceShortcut? {
            guard let code = settings[prefix + "KeyCode"] as? NSNumber,
                  let flags = settings[prefix + "ModifierFlags"] as? NSNumber else {
                throw DirectInputError.message("豆包快捷键设置格式已变化，请更新远控听写")
            }
            if code.intValue == -1 { return nil }
            guard (0...126).contains(code.intValue), code.intValue != 57,
                  flags.int64Value >= 0 else {
                throw DirectInputError.message("豆包当前快捷键暂不支持（例如 Caps Lock），请换用普通键或修饰键组合")
            }
            let key = UInt16(code.intValue)
            // Doubao stores a standalone Fn as keyCode=63, flags=0. HID
            // flagsChanged events still carry maskSecondaryFn while it is down.
            // Normalize this observed representation for matching and replay;
            // other incomplete modifier settings must continue to fail closed.
            let raw = key == 63 && flags.uint64Value == 0
                ? CGEventFlags.maskSecondaryFn.rawValue : flags.uint64Value
            let logical = CGEventFlags(rawValue: raw).intersection(VoiceShortcut.logicalMask)
            if let modifier = VoiceShortcut.modifierFlags[key], !logical.contains(modifier) {
                throw DirectInputError.message("豆包修饰键设置不完整，等待设置保存")
            }
            let display = (settings[prefix + "KeyDisplay"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "键码 \(key)"
            return VoiceShortcut(keyCode: key, flags: raw, display: display)
        }
        return try Self(hold: shortcut("asrLongPressShortcut"), tap: shortcut("asrShortcut"))
    }
}

// Read only the settings record, never account storage, recordings, or history.
// MMKV is append-only; honoring its active size, CRC and latest value avoids
// treating stale/deleted shortcut settings as current configuration.
enum DoubaoShortcutSettings {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DoubaoIme/.com.apple.xpc.activityd/com.apple.xpc.activity")
    }
    static func read() throws -> DoubaoShortcutConfiguration {
        let path = settingsURL
        let crcURL = URL(fileURLWithPath: path.path + ".crc")
        let before = try Data(contentsOf: crcURL)
        let data = try Data(contentsOf: path)
        let after = try Data(contentsOf: crcURL)
        guard before == after else { throw DirectInputError.message("豆包正在保存快捷键，稍后自动重试") }
        return try decodeArchive(settingsRecord(data: data, metadata: before))
    }
    static func decodeArchive(_ archive: Data) throws -> DoubaoShortcutConfiguration {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        guard let settings = unarchiver.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self], forKey: NSKeyedArchiveRootObjectKey) as? [String: Any] else {
            throw DirectInputError.message("无法解析豆包快捷键设置")
        }
        return try DoubaoShortcutConfiguration.decode(settings)
    }
    static func settingsRecord(data: Data, metadata: Data) throws -> Data {
        func fail() -> DirectInputError { .message("豆包快捷键文件不完整或版本不支持，等待重新读取") }
        func u32(_ bytes: Data, _ offset: Int) throws -> Int {
            guard offset + 4 <= bytes.count else { throw fail() }
            return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        let size = try u32(data, 0)
        guard size > 0, size <= 4 * 1024 * 1024, data.count >= size + 4,
              try u32(metadata, 4) == 4, try u32(metadata, 28) == size else { throw fail() }
        let body = Data(data[4..<(4 + size)])
        let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)) }
        guard crc == UInt(try u32(metadata, 0)) else { throw fail() }
        var cursor = 0
        func varint() throws -> Int {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 63, by: 7) {
                guard cursor < body.count else { throw fail() }
                let byte = body[cursor]; cursor += 1
                value |= UInt64(byte & 127) << shift
                if byte < 128 { guard value <= UInt64(Int.max) else { throw fail() }; return Int(value) }
            }
            throw fail()
        }
        func blob() throws -> Data {
            let length = try varint()
            guard length <= body.count - cursor else { throw fail() }
            defer { cursor += length }
            return Data(body[cursor..<(cursor + length)])
        }
        _ = try varint() // MMKV's initial placeholder length.
        var result: Data?
        while cursor < body.count {
            let key = try blob(), value = try blob()
            if key == Data("d".utf8) { result = value.isEmpty ? nil : value }
        }
        guard let result, result.starts(with: Data("bplist00".utf8)) else { throw fail() }
        return result
    }
}
