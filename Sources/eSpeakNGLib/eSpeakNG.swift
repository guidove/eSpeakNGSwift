import ESpeakNG

//  Kokoro-tts-lib — forked to add multilingual support
//
import Foundation

// ESpeakNG wrapper for phonemizing text strings
public final class eSpeakNG {
  private var languageMapping: [String: String] = [:]
  private var language: Language = .none

  public enum ESpeakNGEngineError: Error {
    case dataBundleNotFound
    case couldNotInitialize
    case languageNotFound
    case internalError
    case languageNotSet
    case couldNotPhonemize
  }

  // Available languages — matches Kokoro model's supported languages
  public enum Language: String, CaseIterable {
    case none = ""
    case enUS = "en-us"
    case enGB = "en-gb"
    case ja = "ja"
    case zh = "zh"
    case es = "es"
    case fr = "fr"
    case hi = "hi"
    case it = "it"
    case pt = "pt-br"

    /// Locale identifier for NumberFormatter
    var localeIdentifier: String {
      switch self {
      case .none, .enUS: return "en_US"
      case .enGB: return "en_GB"
      case .ja: return "ja"
      case .zh: return "zh_Hans"
      case .es: return "es"
      case .fr: return "fr"
      case .hi: return "hi"
      case .it: return "it"
      case .pt: return "pt_BR"
      }
    }
  }

  // After constructing the wrapper, call setLanguage() before phonemizing any text
  public init() throws {
    if let bundleURLStr = findDataBundlePath() {
      let initOK = espeak_Initialize(AUDIO_OUTPUT_PLAYBACK, 0, bundleURLStr, 0)

      if initOK != Constants.successAudioSampleRate {
        throw ESpeakNGEngineError.couldNotInitialize
      }

      var languageList: Set<String> = []
      let voiceList = espeak_ListVoices(nil)
      var index = 0
      while let voicePointer = voiceList?.advanced(by: index).pointee {
        let voice = voicePointer.pointee
        if let cLang = voice.languages {
          let language = String(cString: cLang, encoding: .utf8)!
            .replacingOccurrences(of: "\u{05}", with: "")
            .replacingOccurrences(of: "\u{02}", with: "")
          languageList.insert(language)

          if let cName = voice.identifier {
            let name = String(cString: cName, encoding: .utf8)!
              .replacingOccurrences(of: "\u{05}", with: "")
              .replacingOccurrences(of: "\u{02}", with: "")
            languageMapping[language] = name
          }
        }

        index += 1
      }

      // Only validate that at least English is available — other languages are optional
      for lang in [Language.enUS, Language.enGB] {
        if !languageList.contains(lang.rawValue) {
          throw ESpeakNGEngineError.languageNotFound
        }
      }
    } else {
      throw ESpeakNGEngineError.dataBundleNotFound
    }
  }

  deinit {
    _ = espeak_Terminate()
  }

  // Sets the language for phonemization
  public func setLanguage(language: Language) throws {
    guard let name = languageMapping[language.rawValue]
    else {
      throw ESpeakNGEngineError.languageNotFound
    }

    let result = espeak_SetVoiceByName((name as NSString).utf8String)

    if result == EE_NOT_FOUND {
      throw ESpeakNGEngineError.languageNotFound
    } else if result != EE_OK {
      throw ESpeakNGEngineError.internalError
    }

    self.language = language
  }

  // Phonemizes the text string, preserving punctuation for Kokoro pause tokens.
  // Splits text on punctuation boundaries, phonemizes each clause, then reassembles with punctuation.
  public func phonemize(text: String) throws -> String {
    guard language != .none else {
      throw ESpeakNGEngineError.languageNotSet
    }

    guard !text.isEmpty else {
      return ""
    }

    // Spell out numbers before phonemizing
    let preprocessed = Self.expandNumbers(text, language: language)
    if preprocessed != text {
      print("[eSpeakNG] expandNumbers: \"\(text.prefix(80))\" → \"\(preprocessed.prefix(80))\"")
    }

    // Split text into clauses at punctuation boundaries, preserving the punctuation marks
    let clauses = Self.splitIntoClauses(preprocessed)

    var phonemeResult: [String] = []

    for clause in clauses {
      if clause.count == 1 && ".!?;:,".contains(clause) {
        // This is a punctuation mark — pass through directly as a Kokoro token
        phonemeResult.append(clause)
        continue
      }

      // Phonemize this clause via eSpeakNG
      let phonemes = try phonemizeRaw(clause)
      if !phonemes.isEmpty {
        phonemeResult.append(phonemes)
      }
    }

    if !phonemeResult.isEmpty {
      let joined = phonemeResult.joined(separator: " ")
      let processed = postProcessPhonemes(joined)
      print("[eSpeakNG] phonemes: \"\(processed.prefix(150))\"")
      return processed
    } else {
      throw ESpeakNGEngineError.couldNotPhonemize
    }
  }

  /// Raw phonemization of a single clause (no punctuation handling)
  private func phonemizeRaw(_ text: String) throws -> String {
    var textPtr = UnsafeRawPointer((text as NSString).utf8String)
    let phonemes_mode = Int32((Int32(Character("_").asciiValue!) << 8) | 0x02)

    let result = withUnsafeMutablePointer(to: &textPtr) { ptr in
      var resultWords: [String] = []
      while ptr.pointee != nil {
        let phonemes = ESpeakNG.espeak_TextToPhonemes(ptr, espeakCHARS_UTF8, phonemes_mode)
        if let phonemes {
          let word = String(cString: phonemes, encoding: .utf8)!
          if !word.isEmpty {
            resultWords.append(word)
          }
        }
      }
      return resultWords
    }

    return result.joined(separator: " ")
  }

  /// Split text into alternating [clause, punctuation, clause, punctuation, ...] parts
  private static func splitIntoClauses(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""

    for ch in text {
      if ".!?;:,".contains(ch) {
        // Flush current clause
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          result.append(trimmed)
        }
        result.append(String(ch))
        current = ""
      } else {
        current.append(ch)
      }
    }

    // Flush remaining text
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty {
      result.append(trimmed)
    }

    return result
  }

  /// Expand numbers to words for better TTS pronunciation, localized to the active language
  private static func expandNumbers(_ text: String, language: Language) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = Locale(identifier: language.localeIdentifier)

    // Replace standalone numbers (integers and decimals) with their word form
    let pattern = #"\b\d+(\.\d+)?\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

    var result = text
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

    // Replace in reverse to preserve ranges
    for match in matches.reversed() {
      guard let range = Range(match.range, in: text) else { continue }
      let numberStr = String(text[range])

      if let number = Double(numberStr) {
        if number == number.rounded() && !numberStr.contains(".") {
          if let words = formatter.string(from: NSNumber(value: Int(number))) {
            result.replaceSubrange(range, with: words)
          }
        } else {
          // Decimal — spell out whole and fractional parts
          let parts = numberStr.split(separator: ".")
          if parts.count == 2,
             let whole = Int(parts[0]),
             let wholeWords = formatter.string(from: NSNumber(value: whole)) {
            let decimalDigits = parts[1].map { String($0) }.joined(separator: " ")
            result.replaceSubrange(range, with: "\(wholeWords) point \(decimalDigits)")
          }
        }
      }
    }
    return result
  }

  // Post-process phonemes — English needs specific mappings, other languages pass through
  private func postProcessPhonemes(_ phonemes: String) -> String {
    var result = phonemes.trimmingCharacters(in: .whitespacesAndNewlines)

    // Only apply English-specific phoneme mappings for English
    guard language == .enUS || language == .enGB else {
      return result
    }

    for (old, new) in Constants.E2M {
      result = result.replacingOccurrences(of: old, with: new)
    }

    result = result.replacingOccurrences(of: "(\\S)\u{0329}", with: "ᵊ$1", options: .regularExpression)
    result = result.replacingOccurrences(of: "\u{0329}", with: "")

    if language == .enGB {
      result = result.replacingOccurrences(of: "e^ə", with: "ɛː")
      result = result.replacingOccurrences(of: "iə", with: "ɪə")
      result = result.replacingOccurrences(of: "ə^ʊ", with: "Q")
    } else {
      result = result.replacingOccurrences(of: "o^ʊ", with: "O")
      result = result.replacingOccurrences(of: "ɜːɹ", with: "ɜɹ")
      result = result.replacingOccurrences(of: "ɜː", with: "ɜɹ")
      result = result.replacingOccurrences(of: "ɪə", with: "iə")
      result = result.replacingOccurrences(of: "ː", with: "")
    }

    // For espeak < 1.52
    result = result.replacingOccurrences(of: "o", with: "ɔ")
    return result.replacingOccurrences(of: "^", with: "")
  }

  // Find the data bundle inside the framework
  private func findDataBundlePath() -> String? {
    if let frameworkBundle = Bundle(identifier: "com.kokoro.espeakng"),
       let dataBundleURL = frameworkBundle.url(forResource: "espeak-ng-data", withExtension: "bundle")
    {
      return dataBundleURL.path
    }
    return nil
  }

  private enum Constants {
    static let successAudioSampleRate = 22050

    static let E2M: [(String, String)] = [
      ("ʔˌn\u{0329}", "tn"), ("ʔn\u{0329}", "tn"), ("ʔn", "tn"), ("ʔ", "t"),
      ("a^ɪ", "I"), ("a^ʊ", "W"),
      ("d^ʒ", "ʤ"),
      ("e^ɪ", "A"), ("e", "A"),
      ("t^ʃ", "ʧ"),
      ("ɔ^ɪ", "Y"),
      ("ə^l", "ᵊl"),
      ("ʲo", "jo"), ("ʲə", "jə"), ("ʲ", ""),
      ("ɚ", "əɹ"),
      ("r", "ɹ"),
      ("x", "k"), ("ç", "k"),
      ("ɐ", "ə"),
      ("ɬ", "l"),
      ("\u{0303}", ""),
    ].sorted(by: { $0.0.count > $1.0.count })
  }
}
