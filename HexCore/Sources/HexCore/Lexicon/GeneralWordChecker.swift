import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Answers whether a word is an ordinary word of a language. The corrector
/// never fuzzy-replaces valid general words (prevents "Anatomie → anatomy").
public protocol GeneralWordChecker: Sendable {
	func isValidWord(_ word: String, language: String) -> Bool
}

/// Fixed word set, for tests.
public struct SetWordChecker: GeneralWordChecker {
	public let words: Set<String>
	public init(_ words: Set<String>) { self.words = Set(words.map { $0.lowercased() }) }
	public func isValidWord(_ word: String, language: String) -> Bool { words.contains(word.lowercased()) }
}

#if canImport(AppKit)
/// `NSSpellChecker` based checker with a cache. NSSpellChecker is not
/// thread-safe, so lookups hop to the main thread.
public final class SystemWordChecker: GeneralWordChecker, @unchecked Sendable {
	public static let shared = SystemWordChecker()
	private let lock = NSLock()
	private var cache: [String: Bool] = [:]

	public init() {}

	public func isValidWord(_ word: String, language: String) -> Bool {
		let key = "\(language):\(word.lowercased())"
		lock.lock()
		if let cached = cache[key] { lock.unlock(); return cached }
		lock.unlock()
		let valid: Bool
		if Thread.isMainThread {
			valid = Self.check(word, language: language)
		} else {
			valid = DispatchQueue.main.sync { Self.check(word, language: language) }
		}
		lock.lock()
		if cache.count > 50_000 { cache.removeAll() }
		cache[key] = valid
		lock.unlock()
		return valid
	}

	private static func check(_ word: String, language: String) -> Bool {
		let checker = NSSpellChecker.shared
		let identifier = language == "en" ? "en" : language == "de" ? "de" : language
		guard checker.availableLanguages.contains(where: { $0.hasPrefix(identifier) }) else { return false }
		let language = checker.availableLanguages.first(where: { $0 == identifier })
			?? checker.availableLanguages.first(where: { $0.hasPrefix(identifier) })
		var wordCount = 0
		let range = checker.checkSpelling(
			of: word, startingAt: 0, language: language, wrap: false,
			inSpellDocumentWithTag: 0, wordCount: &wordCount
		)
		return range.location == NSNotFound
	}
}
#endif
