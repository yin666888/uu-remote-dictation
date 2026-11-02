import Foundation

enum UTF16TextRange {
    static func isValid(_ range: NSRange, in text: String) -> Bool {
        let units = Array(text.utf16)
        guard range.location != NSNotFound, range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        func boundary(_ offset: Int) -> Bool {
            guard offset > 0 && offset < units.count else { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
}

// Tracks only this dictation's replacement range. Never rewrites surrounding
// text; every write is conditional on the document and selection still matching.
struct DirectInputReplacement {
    let original: String
    let originalRange: NSRange
    private(set) var preview: String?

    init(original: String, selection: NSRange) throws {
        guard selection.location != NSNotFound,
              selection.location <= original.utf16.count,
              selection.length <= original.utf16.count - selection.location,
              UTF16TextRange.isValid(selection, in: original) else {
            throw DirectInputError.message("输入框的文字范围无效")
        }
        self.original = original
        self.originalRange = selection
    }
    var range: NSRange {
        NSRange(location: originalRange.location, length: preview?.utf16.count ?? originalRange.length)
    }
    var selection: NSRange {
        preview == nil ? originalRange : NSRange(location: NSMaxRange(range), length: 0)
    }
    var expectedValue: String {
        guard let preview else { return original }
        return (original as NSString).replacingCharacters(in: originalRange, with: preview)
    }
    var originalSelectionText: String { (original as NSString).substring(with: originalRange) }
    func validate(value: String, selection: NSRange) throws {
        guard value == expectedValue, selection == self.selection else {
            throw DirectInputError.message("输入框内容或光标已改变，已停止实时更新，请检查已显示的文字")
        }
    }
    mutating func didWrite(_ text: String) { preview = text }
}
