import AppKit
import HexCore

extension NSAttributedString.Key {
  /// Original spelling of an automatic lexicon replacement (blue dotted underline).
  static let localASRCorrectionOriginal = NSAttributedString.Key("LocalASRCorrectionOriginal")
  /// Word the engine was unsure about (orange dotted underline).
  static let localASRUncertain = NSAttributedString.Key("LocalASRUncertain")
  /// Heading level of a paragraph (1 = H1, 2 = H2).
  static let localASRHeading = NSAttributedString.Key("LocalASRHeading")
}

/// Immutable attributed text as TCA state value.
struct BoxText: Equatable, @unchecked Sendable {
  var value: NSAttributedString

  init(_ value: NSAttributedString = NSAttributedString()) {
    self.value = value.copy() as! NSAttributedString
  }

  var string: String { value.string }
  var length: Int { value.length }

  static func == (lhs: BoxText, rhs: BoxText) -> Bool {
    lhs.value.isEqual(to: rhs.value)
  }
}

enum BoxTextStyle {
  static let fontChoices: [(name: String, title: String)] = [
    ("", "System"), (".serif", "New York"), (".mono", "SF Mono"), ("Helvetica Neue", "Helvetica Neue"),
    ("Avenir Next", "Avenir Next"), ("Georgia", "Georgia"), ("Times New Roman", "Times New Roman"), ("Arial", "Arial"),
  ]

  static func baseFont(name: String, size: Double) -> NSFont {
    let size = CGFloat(min(max(size, 11), 28))
    switch name {
    case "": return .systemFont(ofSize: size)
    case ".serif":
      let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
      return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    case ".mono": return .monospacedSystemFont(ofSize: size, weight: .regular)
    default: return NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }
  }

  static func headingFont(base: NSFont, level: Int) -> NSFont {
    let size = base.pointSize * (level == 1 ? 1.45 : 1.2)
    let resized = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
    return NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
  }

  static func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.textColor]
  }

  static func correctionAttributes(original: String) -> [NSAttributedString.Key: Any] {
    [
      .localASRCorrectionOriginal: original,
      .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
      .underlineColor: NSColor.systemBlue,
    ]
  }
}

// MARK: - Conversion

enum BoxTextConverter {
  /// Assembler markdown (`# `, `- `, `1. `, `**bold**`, `*italic*`) → attributed text.
  static func attributed(fromMarkdown markdown: String, baseFont: NSFont, corrections: [LexiconCorrection] = []) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = markdown.components(separatedBy: "\n")
    for (index, rawLine) in lines.enumerated() {
      var line = Substring(rawLine)
      var lineFont = baseFont
      var heading: Int?
      if line.hasPrefix("## ") {
        heading = 2; line = line.dropFirst(3)
      } else if line.hasPrefix("# ") {
        heading = 1; line = line.dropFirst(2)
      }
      if let heading { lineFont = BoxTextStyle.headingFont(base: baseFont, level: heading) }
      var prefix = ""
      if line.hasPrefix("- ") {
        prefix = "• "; line = line.dropFirst(2)
      }
      let lineStart = result.length
      if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: BoxTextStyle.attributes(font: lineFont))) }
      appendInline(String(line), font: lineFont, to: result)
      if let heading {
        result.addAttribute(.localASRHeading, value: heading, range: NSRange(location: lineStart, length: result.length - lineStart))
      }
      if index < lines.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: BoxTextStyle.attributes(font: baseFont)))
      }
    }
    markCorrections(corrections, in: result)
    return result
  }

  private static func appendInline(_ line: String, font: NSFont, to result: NSMutableAttributedString) {
    var bold = false, italic = false
    var buffer = ""
    func flush() {
      guard !buffer.isEmpty else { return }
      var styled = font
      if bold { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
      if italic { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
      result.append(NSAttributedString(string: buffer, attributes: BoxTextStyle.attributes(font: styled)))
      buffer = ""
    }
    var characters = Array(line)[...]
    while let character = characters.first {
      if character == "*" {
        flush()
        if characters.dropFirst().first == "*" {
          bold.toggle(); characters = characters.dropFirst(2)
        } else {
          italic.toggle(); characters = characters.dropFirst()
        }
        continue
      }
      buffer.append(character)
      characters = characters.dropFirst()
    }
    flush()
  }

  /// Underlines each replacement once, in order (the same term can occur several times).
  static func markCorrections(_ corrections: [LexiconCorrection], in text: NSMutableAttributedString) {
    var searchStart = 0
    let string = text.string as NSString
    for correction in corrections {
      let range = string.range(of: correction.replacement, options: [], range: NSRange(location: searchStart, length: string.length - searchStart))
      guard range.location != NSNotFound else { continue }
      text.addAttributes(BoxTextStyle.correctionAttributes(original: correction.original), range: range)
      searchStart = range.location + range.length
    }
  }

  /// Orange dotted underline for low-confidence words (whole-word matches,
  /// skipping words that already carry a lexicon correction).
  static func markUncertain(_ words: [String], in text: NSMutableAttributedString) {
    let string = text.string as NSString
    for word in words {
      var searchRange = NSRange(location: 0, length: string.length)
      while true {
        let range = string.range(of: word, options: [.caseInsensitive], range: searchRange)
        guard range.location != NSNotFound else { break }
        let before = range.location > 0 ? string.character(at: range.location - 1) : 32
        let afterIndex = range.location + range.length
        let after = afterIndex < string.length ? string.character(at: afterIndex) : 32
        let isWord = !(UnicodeScalar(before).map(CharacterSet.alphanumerics.contains) ?? false)
          && !(UnicodeScalar(after).map(CharacterSet.alphanumerics.contains) ?? false)
        if isWord, text.attribute(.localASRCorrectionOriginal, at: range.location, effectiveRange: nil) == nil {
          text.addAttributes([
            .localASRUncertain: true,
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.systemOrange,
          ], range: range)
        }
        searchRange = NSRange(location: afterIndex, length: string.length - afterIndex)
      }
    }
  }

  /// Copy without the box-only markers (correction underline etc.).
  static func exportCopy(_ text: NSAttributedString) -> NSAttributedString {
    let copy = NSMutableAttributedString(attributedString: text)
    let full = NSRange(location: 0, length: copy.length)
    copy.removeAttribute(.localASRCorrectionOriginal, range: full)
    copy.removeAttribute(.localASRUncertain, range: full)
    copy.removeAttribute(.underlineStyle, range: full)
    copy.removeAttribute(.underlineColor, range: full)
    copy.removeAttribute(.localASRHeading, range: full)
    return copy
  }

  static func rtf(from text: NSAttributedString) -> Data? {
    let export = exportCopy(text)
    return try? export.data(
      from: NSRange(location: 0, length: export.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
  }

  static func plainText(from text: NSAttributedString) -> String {
    text.string.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Attributed text → Markdown (headings, bullets, bold, italic).
  static func markdown(from text: NSAttributedString) -> String {
    let string = text.string as NSString
    var lines: [String] = []
    var location = 0
    while location <= string.length {
      let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
      var contentRange = lineRange
      while contentRange.length > 0, let scalar = UnicodeScalar(string.character(at: contentRange.location + contentRange.length - 1)),
            CharacterSet.newlines.contains(scalar) {
        contentRange.length -= 1
      }
      var line = ""
      var heading: Int?
      if contentRange.length > 0 {
        heading = text.attribute(.localASRHeading, at: contentRange.location, effectiveRange: nil) as? Int
        text.enumerateAttribute(.font, in: contentRange) { value, range, _ in
          let piece = string.substring(with: range)
          let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
          let bold = traits.contains(.boldFontMask) && heading == nil
          let italic = traits.contains(.italicFontMask)
          let trimmed = piece.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty, bold || italic else { line += piece; return }
          let marker = bold && italic ? "***" : bold ? "**" : "*"
          let leading = String(piece.prefix(while: { $0 == " " }))
          let trailing = String(piece.reversed().prefix(while: { $0 == " " }))
          line += leading + marker + trimmed + marker + trailing
        }
      }
      if line.hasPrefix("• ") { line = "- " + line.dropFirst(2) }
      if let heading { line = String(repeating: "#", count: heading) + " " + line }
      lines.append(line)
      if lineRange.length == 0 { break }
      location = lineRange.location + lineRange.length
      if location == string.length { break }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Editing

enum BoxTextEditing {
  /// Inserts `inserted` at `range` (replacing it) with sensible spacing.
  /// Returns the new text and the range the inserted text now occupies.
  static func insert(_ inserted: NSAttributedString, into text: NSAttributedString, replacing range: NSRange) -> (NSAttributedString, NSRange) {
    let result = NSMutableAttributedString(attributedString: text)
    let clamped = clamp(range, length: result.length)
    result.replaceCharacters(in: clamped, with: "")
    let piece = NSMutableAttributedString(attributedString: inserted)
    let string = result.string as NSString
    let before: Character? = clamped.location > 0 ? Character(UnicodeScalar(string.character(at: clamped.location - 1))!) : nil
    let after: Character? = clamped.location < string.length ? Character(UnicodeScalar(string.character(at: clamped.location))!) : nil
    let attributes = piece.length > 0 ? piece.attributes(at: 0, effectiveRange: nil) : [:]
    let neutral = attributes.filter { $0.key == .font || $0.key == .foregroundColor }
    let startsWithPunctuation = piece.string.first.map { ".,;:!?)]}“”".contains($0) } ?? false
    if let before, !before.isWhitespace, !"([{„“\n".contains(before), !startsWithPunctuation, piece.length > 0 {
      piece.insert(NSAttributedString(string: " ", attributes: neutral), at: 0)
    }
    if let after, !after.isWhitespace, !".,;:!?)]}“”".contains(after), piece.length > 0,
       piece.string.last.map({ !$0.isWhitespace }) == true {
      piece.append(NSAttributedString(string: " ", attributes: neutral))
    }
    result.insert(piece, at: clamped.location)
    return (result, NSRange(location: clamped.location, length: piece.length))
  }

  static func clamp(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    return NSRange(location: location, length: min(max(range.length, 0), length - location))
  }

  /// Toggles bold/italic on `range` (all fonts have the trait → remove, else add).
  static func toggleTrait(_ trait: NSFontTraitMask, in text: NSAttributedString, range: NSRange) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let range = clamp(range, length: result.length)
    guard range.length > 0 else { return result }
    var allHave = true
    result.enumerateAttribute(.font, in: range) { value, _, _ in
      if let font = value as? NSFont, !NSFontManager.shared.traits(of: font).contains(trait) { allHave = false }
    }
    result.enumerateAttribute(.font, in: range) { value, subrange, _ in
      guard let font = value as? NSFont else { return }
      let converted = allHave
        ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        : NSFontManager.shared.convert(font, toHaveTrait: trait)
      result.addAttribute(.font, value: converted, range: subrange)
    }
    return result
  }

  /// Makes the paragraphs touched by `range` a heading (or back to body text).
  static func toggleHeading(in text: NSAttributedString, range: NSRange, baseFont: NSFont) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let paragraph = (result.string as NSString).paragraphRange(for: clamp(range, length: result.length))
    guard paragraph.length > 0 else { return result }
    let isHeading = result.attribute(.localASRHeading, at: paragraph.location, effectiveRange: nil) != nil
    if isHeading {
      result.removeAttribute(.localASRHeading, range: paragraph)
      result.addAttribute(.font, value: baseFont, range: paragraph)
    } else {
      result.addAttribute(.localASRHeading, value: 1, range: paragraph)
      result.addAttribute(.font, value: BoxTextStyle.headingFont(base: baseFont, level: 1), range: paragraph)
    }
    return result
  }

  /// Adds or removes „• “ at the start of each paragraph touched by `range`.
  static func toggleBullets(in text: NSAttributedString, range: NSRange, baseFont: NSFont) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let string = result.string as NSString
    let paragraphs = string.paragraphRange(for: clamp(range, length: result.length))
    var starts: [Int] = []
    var location = paragraphs.location
    repeat {
      starts.append(location)
      let line = string.paragraphRange(for: NSRange(location: location, length: 0))
      location = line.location + max(line.length, 1)
    } while location < paragraphs.location + paragraphs.length
    let allBulleted = starts.allSatisfy { string.length >= $0 + 2 && string.substring(with: NSRange(location: $0, length: 2)) == "• " }
    for start in starts.reversed() {
      if allBulleted {
        result.replaceCharacters(in: NSRange(location: start, length: 2), with: "")
      } else if !(string.length >= start + 2 && string.substring(with: NSRange(location: start, length: 2)) == "• ") {
        result.insert(NSAttributedString(string: "• ", attributes: BoxTextStyle.attributes(font: baseFont)), at: start)
      }
    }
    return result
  }

  /// Wraps the selection in language-specific quotation marks.
  static func quote(in text: NSAttributedString, range: NSRange, language: String) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let range = clamp(range, length: result.length)
    guard range.length > 0 else { return result }
    let (open, close) = language.hasPrefix("en") ? ("“", "”") : ("„", "“")
    let attributes = result.attributes(at: range.location, effectiveRange: nil)
    result.insert(NSAttributedString(string: close, attributes: attributes), at: range.location + range.length)
    result.insert(NSAttributedString(string: open, attributes: attributes), at: range.location)
    return result
  }

  /// lower → Capitalized → UPPER → lower.
  static func cycleCase(in text: NSAttributedString, range: NSRange) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let range = clamp(range, length: result.length)
    guard range.length > 0 else { return result }
    let selected = (result.string as NSString).substring(with: range)
    let next: String
    if selected == selected.uppercased(), selected != selected.lowercased() {
      next = selected.lowercased()
    } else if selected == selected.lowercased() {
      next = selected.prefix(1).uppercased() + selected.dropFirst()
    } else {
      next = selected.uppercased()
    }
    result.replaceCharacters(in: range, with: next)
    return result
  }

  /// Applies a new base font (family + size), keeping bold/italic and headings.
  static func applyBaseFont(_ base: NSFont, to text: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let full = NSRange(location: 0, length: result.length)
    result.enumerateAttribute(.font, in: full) { value, range, _ in
      let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
      var font = base
      if let level = result.attribute(.localASRHeading, at: range.location, effectiveRange: nil) as? Int {
        font = BoxTextStyle.headingFont(base: base, level: level)
      }
      if traits.contains(.boldFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
      if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
      result.addAttribute(.font, value: font, range: range)
    }
    return result
  }

  /// Range of the word at `index` (letters, digits, hyphen, apostrophe).
  static func wordRange(at index: Int, in string: String) -> NSRange? {
    let text = string as NSString
    guard text.length > 0 else { return nil }
    func isWordCharacter(_ position: Int) -> Bool {
      guard position >= 0, position < text.length, let scalar = UnicodeScalar(text.character(at: position)) else { return false }
      return CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "'"
    }
    var start = min(max(index, 0), text.length - 1)
    if !isWordCharacter(start) { return nil }
    var end = start
    while start > 0, isWordCharacter(start - 1) { start -= 1 }
    while end < text.length, isWordCharacter(end) { end += 1 }
    return NSRange(location: start, length: end - start)
  }

  static func wordCount(_ string: String) -> Int {
    string.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
  }

  static func deleteLastWord(_ text: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let string = result.string as NSString
    var end = string.length
    while end > 0, let scalar = UnicodeScalar(string.character(at: end - 1)),
          !CharacterSet.alphanumerics.contains(scalar) { end -= 1 }
    guard end > 0, let range = wordRange(at: end - 1, in: result.string) else { return result }
    var start = range.location
    while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)), scalar == " " { start -= 1 }
    result.deleteCharacters(in: NSRange(location: start, length: string.length - start))
    return result
  }

  static func deleteLastSentence(_ text: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let string = result.string as NSString
    var end = string.length
    while end > 0, let scalar = UnicodeScalar(string.character(at: end - 1)),
          ".?!\n ".unicodeScalars.contains(scalar) { end -= 1 }
    var start = end
    while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)),
          !".?!\n".unicodeScalars.contains(scalar) { start -= 1 }
    while start < end, let scalar = UnicodeScalar(string.character(at: start)), scalar == " " { start += 1 }
    var cut = start
    while cut > 0, let scalar = UnicodeScalar(string.character(at: cut - 1)), scalar == " " { cut -= 1 }
    result.deleteCharacters(in: NSRange(location: cut, length: string.length - cut))
    return result
  }
}
