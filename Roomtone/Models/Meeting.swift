import Foundation

struct Meeting: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var date: Date
    var durationSeconds: TimeInterval
    var speakers: [String]
    var summaryProvider: String?
    var status: MeetingStatus
    var tags: [String]
    var folderName: String
    var audio: MeetingAudioFiles?

    enum CodingKeys: String, CodingKey {
        case id, title, date, durationSeconds, speakers, summaryProvider, status, tags, folderName, audio
    }
}

struct MeetingAudioFiles: Codable, Hashable {
    var system: String
    var microphone: String
    var combined: String
}

enum MeetingStatus: String, Codable, Hashable {
    case created
    case recording
    case recorded
    case transcribing
    case transcribed
    case summarized
    case ready
    case failed

    /// Sidebar label. nil for the normal finished state, so only noteworthy states show.
    var displayLabel: String? {
        switch self {
        case .created: return "New"
        case .recording: return "Recording"
        case .recorded: return "Recorded"
        case .transcribing: return "Transcribing…"
        case .transcribed: return "Transcribed"
        case .summarized: return "Summarized"
        case .ready: return nil
        case .failed: return "Failed"
        }
    }
}

struct Transcript: Codable, Hashable {
    var blocks: [TranscriptBlock]
    var speakers: [String]
    var language: String?
}

struct TranscriptBlock: Identifiable, Codable, Hashable {
    var id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String
    var text: String

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

struct MeetingSummary: Codable, Hashable {
    var overview: String
    var keyDecisions: [String]
    var actionItems: [String]
    var risks: [String]
    var openQuestions: [String]
    var followUps: [String]
    var attendees: [String]
    var markdown: String
    var provider: String
}


enum WhisperModel: String, Codable, CaseIterable, Identifiable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case mediumEn = "medium.en"
    case base = "base"
    case small = "small"
    case medium = "medium"

    var id: String { rawValue }

    enum Size: Equatable {
        case base, small, medium
    }

    var size: Size {
        switch self {
        case .base, .baseEn: return .base
        case .small, .smallEn: return .small
        case .medium, .mediumEn: return .medium
        }
    }

    /// `.en` English-only vs multilingual.
    var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }

    var displayName: String {
        switch self {
        case .baseEn: return "base.en — ~145 MB, faster"
        case .smallEn: return "small.en — ~500 MB, better (default)"
        case .mediumEn: return "medium.en — ~1.5 GB, heavier"
        case .base: return "base — ~145 MB, faster (multilingual)"
        case .small: return "small — ~500 MB, better (multilingual)"
        case .medium: return "medium — ~1.5 GB, heavier (multilingual)"
        }
    }

    func converted(englishOnly: Bool) -> WhisperModel {
        switch (size, englishOnly) {
        case (.base, true): return .baseEn
        case (.base, false): return .base
        case (.small, true): return .smallEn
        case (.small, false): return .small
        case (.medium, true): return .mediumEn
        case (.medium, false): return .medium
        }
    }

    static func models(englishOnly: Bool) -> [WhisperModel] {
        englishOnly
            ? [.baseEn, .smallEn, .mediumEn]
            : [.base, .small, .medium]
    }
}

/// ISO codes accepted by OpenAI Whisper / faster-whisper (`--language`).
enum WhisperLanguage: String, Codable, CaseIterable, Identifiable {
    case auto
    case af, am, ar
    case `as` = "as"
    case az, ba, be, bg, bn, bo, br, bs, ca, cs, cy, da, de, el, en, es, et
    case eu, fa, fi, fo, fr, gl, gu, ha, haw, he, hi, hr, ht, hu, hy
    case indonesian = "id"
    case `is` = "is"
    case it, ja, jw
    case ka, kk, km, kn, ko, la, lb, ln, lo, lt, lv, mg, mi, mk, ml, mn, mr, ms, mt, my
    case ne, nl, nn, no, oc, pa, pl, ps, pt, ro, ru, sa, sd, si, sk, sl, sn, so, sq, sr
    case su, sv, sw, ta, te, tg, th, tk, tl, tr, tt, uk, ur, uz, vi, yi, yo, yue, zh

    var id: String { rawValue }

    /// Value passed to the ASR sidecar (`auto` → detect).
    var sidecarCode: String { self == .auto ? "auto" : rawValue }

    /// English → `.en` models; auto / other languages → multilingual.
    var prefersEnglishOnlyModel: Bool { self == .en }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .af: return "Afrikaans"
        case .am: return "Amharic"
        case .ar: return "Arabic"
        case .as: return "Assamese"
        case .az: return "Azerbaijani"
        case .ba: return "Bashkir"
        case .be: return "Belarusian"
        case .bg: return "Bulgarian"
        case .bn: return "Bengali"
        case .bo: return "Tibetan"
        case .br: return "Breton"
        case .bs: return "Bosnian"
        case .ca: return "Catalan"
        case .cs: return "Czech"
        case .cy: return "Welsh"
        case .da: return "Danish"
        case .de: return "German"
        case .el: return "Greek"
        case .en: return "English"
        case .es: return "Spanish"
        case .et: return "Estonian"
        case .eu: return "Basque"
        case .fa: return "Persian"
        case .fi: return "Finnish"
        case .fo: return "Faroese"
        case .fr: return "French"
        case .gl: return "Galician"
        case .gu: return "Gujarati"
        case .ha: return "Hausa"
        case .haw: return "Hawaiian"
        case .he: return "Hebrew"
        case .hi: return "Hindi"
        case .hr: return "Croatian"
        case .ht: return "Haitian Creole"
        case .hu: return "Hungarian"
        case .hy: return "Armenian"
        case .indonesian: return "Indonesian"
        case .is: return "Icelandic"
        case .it: return "Italian"
        case .ja: return "Japanese"
        case .jw: return "Javanese"
        case .ka: return "Georgian"
        case .kk: return "Kazakh"
        case .km: return "Khmer"
        case .kn: return "Kannada"
        case .ko: return "Korean"
        case .la: return "Latin"
        case .lb: return "Luxembourgish"
        case .ln: return "Lingala"
        case .lo: return "Lao"
        case .lt: return "Lithuanian"
        case .lv: return "Latvian"
        case .mg: return "Malagasy"
        case .mi: return "Maori"
        case .mk: return "Macedonian"
        case .ml: return "Malayalam"
        case .mn: return "Mongolian"
        case .mr: return "Marathi"
        case .ms: return "Malay"
        case .mt: return "Maltese"
        case .my: return "Myanmar"
        case .ne: return "Nepali"
        case .nl: return "Dutch"
        case .nn: return "Nynorsk"
        case .no: return "Norwegian"
        case .oc: return "Occitan"
        case .pa: return "Punjabi"
        case .pl: return "Polish"
        case .ps: return "Pashto"
        case .pt: return "Portuguese"
        case .ro: return "Romanian"
        case .ru: return "Russian"
        case .sa: return "Sanskrit"
        case .sd: return "Sindhi"
        case .si: return "Sinhala"
        case .sk: return "Slovak"
        case .sl: return "Slovenian"
        case .sn: return "Shona"
        case .so: return "Somali"
        case .sq: return "Albanian"
        case .sr: return "Serbian"
        case .su: return "Sundanese"
        case .sv: return "Swedish"
        case .sw: return "Swahili"
        case .ta: return "Tamil"
        case .te: return "Telugu"
        case .tg: return "Tajik"
        case .th: return "Thai"
        case .tk: return "Turkmen"
        case .tl: return "Tagalog"
        case .tr: return "Turkish"
        case .tt: return "Tatar"
        case .uk: return "Ukrainian"
        case .ur: return "Urdu"
        case .uz: return "Uzbek"
        case .vi: return "Vietnamese"
        case .yi: return "Yiddish"
        case .yo: return "Yoruba"
        case .yue: return "Cantonese"
        case .zh: return "Chinese"
        }
    }

    static func resolved(from stored: String) -> WhisperLanguage {
        let code = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if code.isEmpty || code == "auto" || code == "detect" || code == "none" {
            return .auto
        }
        return WhisperLanguage(rawValue: code) ?? .en
    }

    /// Auto first, then A–Z by English name.
    static var pickerOrder: [WhisperLanguage] {
        let rest = allCases
            .filter { $0 != .auto }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return [.auto] + rest
    }
}

struct AppSettings: Codable, Equatable {
    var outputDirectoryPath: String
    var sampleRate: Double
    var transcriptionLanguage: String
    var transcriptionModel: WhisperModel
    var ai: AISettings
    var exportFormats: [ExportFormat]
    var deleteRecordingsAfterTranscription: Bool
    var neverUploadAutomatically: Bool
    var appearance: AppearancePreference

    static let defaults = AppSettings(
        outputDirectoryPath: "~/Documents/Roomtone",
        sampleRate: 48_000,
        transcriptionLanguage: "en",
        transcriptionModel: .smallEn,
        ai: AISettings(provider: .none, baseURL: "http://127.0.0.1:11434/v1", model: "llama3.2", apiKey: ""),
        exportFormats: [.markdown, .json, .srt],
        deleteRecordingsAfterTranscription: false,
        neverUploadAutomatically: true,
        appearance: .system
    )

    var resolvedOutputDirectory: URL {
        let expanded = NSString(string: outputDirectoryPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Roomtone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    /// File only. `ai.apiKey` is filled from the keychain by `AppModel`, so helpers that
    /// call this for the output folder don't touch the keychain.
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .defaults }
        let settings = decode(data)
        // Older builds stored the key in settings.json. Move it, then rewrite the file without it.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ai = obj["ai"] as? [String: Any],
           let key = ai["apiKey"] as? String,
           key.isEmpty || APIKeyStore.save(key) {
            settings.save()
        }
        return settings
    }

    private static func decode(_ data: Data) -> AppSettings {
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Tolerate older settings missing new keys by merging defaults.
            guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .defaults
            }
            if obj["transcriptionModel"] == nil {
                obj["transcriptionModel"] = WhisperModel.smallEn.rawValue
            }
            // Added after release; without this, older settings.json files reset to defaults.
            if obj["appearance"] == nil {
                obj["appearance"] = AppearancePreference.system.rawValue
            }
            guard let patched = try? JSONSerialization.data(withJSONObject: obj),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: patched) else {
                return .defaults
            }
            return decoded
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct AISettings: Codable, Equatable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    /// Kept in the keychain (`APIKeyStore`); left out of settings.json on purpose.
    var apiKey: String = ""

    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, model
    }

    /// A "local" provider pointed at a remote host still uploads the transcript.
    var leavesMachine: Bool {
        switch provider {
        case .none: return false
        case .openAI: return true
        case .localCompatible:
            let host = URL(string: baseURL)?.host?.lowercased() ?? ""
            return !["", "localhost", "127.0.0.1", "::1"].contains(host)
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case none
    case openAI = "openai"
    case localCompatible = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .openAI: return "OpenAI API"
        case .localCompatible: return "Local OpenAI-compatible"
        }
    }

}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case markdown
    case txt
    case json
    case srt
    case vtt

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .txt: return "txt"
        case .json: return "json"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }
}
