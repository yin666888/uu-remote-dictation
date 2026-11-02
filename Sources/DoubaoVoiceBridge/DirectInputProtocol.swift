import Foundation
import CryptoKit
import Security

enum DirectInputError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct DirectInputMessage: Codable {
    let operation: String
    let session: UUID
    var text: String? = nil
    var error: String? = nil
    var previewSupported: Bool? = nil
    var sequence: Int? = nil
}

enum DirectInputCodec {
    static let maximumFrameSize = 128 * 1024
    static let maximumTextBytes = 48 * 1024

    static func key(from string: String) -> Data? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64 else { return nil }
        var bytes = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    static func encode(_ message: DirectInputMessage, key: Data) throws -> Data {
        guard key.count == 32 else { throw DirectInputError.message("配对码无效") }
        let plaintext = try JSONEncoder().encode(message)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let data = box.combined, data.count <= maximumFrameSize else {
            throw DirectInputError.message("输入内容过长")
        }
        var length = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + data
    }

    static func decode(_ data: Data, key: Data) throws -> DirectInputMessage {
        guard key.count == 32, data.count <= maximumFrameSize else {
            throw DirectInputError.message("输入数据无效")
        }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key))
        return try JSONDecoder().decode(DirectInputMessage.self, from: plaintext)
    }
}

struct DirectInputFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 28, length <= DirectInputCodec.maximumFrameSize else {
                throw DirectInputError.message("输入数据长度无效")
            }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        guard buffer.count <= DirectInputCodec.maximumFrameSize + 4 else {
            throw DirectInputError.message("输入数据过大")
        }
        return frames
    }
}

enum DirectInputSettings {
    static let defaultPort = 0 // Unconfigured; each user chooses their own port.
    static var isReceiver: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DirectInputReceiver") as? Bool == true
    }
    static var port: UInt16 {
        let value = UserDefaults.standard.integer(forKey: "directInputPort")
        return UInt16(exactly: value).flatMap { $0 > 0 ? $0 : nil } ?? UInt16(defaultPort)
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "org.remotedictation.bridge",
         kSecAttrAccount as String: "direct-input-pairing-v1"]
    }
    static func readKey() -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, data.count == 32 else { return nil }
        return data
    }
    static func saveKey(_ data: Data) throws {
        guard data.count == 32 else { throw DirectInputError.message("配对码无效") }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DirectInputError.message("无法保存配对码到钥匙串（\(status)）") }
    }
    static func newKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DirectInputError.message("无法生成配对码")
        }
        return Data(bytes)
    }
}
