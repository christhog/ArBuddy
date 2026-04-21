//
//  AzureSpeechSDKService.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation
import AVFoundation
import Combine

#if canImport(MicrosoftCognitiveServicesSpeech)
import MicrosoftCognitiveServicesSpeech
#endif

// MARK: - Azure Speech SDK Service

/// Native Azure Speech SDK wrapper for TTS with real viseme events.
///
/// Authentication uses short-lived tokens issued by the `azure-speech-token`
/// Edge Function — no subscription key is embedded in the client. Tokens are
/// cached and auto-refreshed ~30 s before expiry.
///
/// Requires:
///  - `MicrosoftCognitiveServicesSpeech-iOS` CocoaPod (~50 MB framework)
///  - Azure Speech Services **Standard tier (S0)** — free F0 does not emit visemes
@MainActor
class AzureSpeechSDKService: ObservableObject {
    static let shared = AzureSpeechSDKService()

    // MARK: - Published Properties

    @Published private(set) var isLoading: Bool = false
    @Published var isEnabled: Bool = true

    // Voice settings (mirrored from AzureSpeechService at call time)
    @Published var selectedVoice: AzureVoice = .katjaNeural
    @Published var speechRate: String = "0%"
    @Published var speechStyle: SpeechStyle = .none
    @Published var styleDegree: Double = 1.0

    // MARK: - Token Cache

    private struct CachedToken {
        let token: String
        let region: String
        let expiresAt: TimeInterval
        var isValid: Bool { Date().timeIntervalSince1970 < expiresAt }
    }

    private var cachedToken: CachedToken?

    // MARK: - Supabase

    private let supabaseURL = "https://ibhaixdirrejsxalntvx.supabase.co"
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImliaGFpeGRpcnJlanN4YWxudHZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg1NjU0NjksImV4cCI6MjA4NDE0MTQ2OX0.966UbEaN19b3leFVi0PR_H1j0F95yAOW8C-oEGHbbyw"

    // MARK: - Init

    private init() {
        loadSettings()
    }

    // MARK: - SDK Availability

    /// True when the CocoaPod framework is linked *and* can be used at runtime.
    func isSDKAvailable() -> Bool {
        #if canImport(MicrosoftCognitiveServicesSpeech)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Public API

    /// One bookmark event surfaced by the SDK during synthesis — used by the
    /// chat layer to flip facial expressions at exact audio offsets.
    struct BookmarkEvent {
        let name: String
        let audioOffsetMs: Int
    }

    /// Result of a synthesis call: MP3 audio bytes + collected viseme events.
    struct SynthesisResult {
        let audioData: Data
        let visemes: [VisemeEvent]
        let bookmarks: [BookmarkEvent]
    }

    /// Synthesizes `text` to audio + viseme stream using the Azure Speech SDK.
    /// Does NOT play audio — caller hands the bytes to `SynchronizedAudioPlayer`
    /// so the lip-sync layer gets a precise playback start time.
    func synthesize(_ text: String) async throws -> SynthesisResult {
        return try await synthesize(segments: [(text: text, emotion: nil)])
    }

    /// Segment-aware variant: for each `(text, emotion)` pair, an SSML
    /// `<bookmark mark="emotion:xxx"/>` is emitted immediately before the
    /// text. Azure fires `bookmarkReached` at the exact audio offset of that
    /// point, which the caller uses to drive facial expression changes.
    func synthesize(segments: [(text: String, emotion: String?)]) async throws -> SynthesisResult {
        let joined = segments.map { $0.text }.joined()
        guard isEnabled, !joined.isEmpty else {
            return SynthesisResult(audioData: Data(), visemes: [], bookmarks: [])
        }
        guard isSDKAvailable() else {
            throw SDKError.sdkNotLinked
        }

        isLoading = true
        defer { isLoading = false }

        let (token, region) = try await fetchToken()

        #if canImport(MicrosoftCognitiveServicesSpeech)
        return try await synthesizeWithSDK(segments: segments, token: token, region: region)
        #else
        throw SDKError.sdkNotLinked
        #endif
    }

    // MARK: - SDK Synthesis

    #if canImport(MicrosoftCognitiveServicesSpeech)
    private func synthesizeWithSDK(segments: [(text: String, emotion: String?)], token: String, region: String) async throws -> SynthesisResult {
        // Azure SDK calls are synchronous and blocking — run off the main actor.
        let voice = selectedVoice.rawValue
        let ssml = buildSSML(segments: segments)

        return try await Task.detached(priority: .userInitiated) {
            let speechConfig = try SPXSpeechConfiguration(authorizationToken: token, region: region)
            speechConfig.speechSynthesisVoiceName = voice
            speechConfig.setSpeechSynthesisOutputFormat(.audio24Khz48KBitRateMonoMp3)

            // Passing a nil audio config makes the SDK write audio into `result.audioData`
            // instead of playing it through the device speaker — exactly what we want.
            let synthesizer = try SPXSpeechSynthesizer(speechConfiguration: speechConfig, audioConfiguration: nil)

            // Thread-safe viseme collector. The viseme callback fires on an
            // internal SDK thread during synthesis.
            let collector = VisemeCollector()
            let bookmarkCollector = BookmarkCollector()

            synthesizer.addVisemeReceivedEventHandler { _, args in
                // args.audioOffset is in 100-ns ticks (UInt64).
                let offsetMs = Int(args.audioOffset / 10_000)
                let visemeId = Int(args.visemeId)
                collector.append(VisemeEvent(visemeId: visemeId, audioOffsetMilliseconds: offsetMs))
            }

            synthesizer.addBookmarkReachedEventHandler { _, args in
                let offsetMs = Int(args.audioOffset / 10_000)
                bookmarkCollector.append(BookmarkEvent(name: args.text, audioOffsetMs: offsetMs))
            }

            let result = try synthesizer.speakSsml(ssml)

            switch result.reason {
            case .synthesizingAudioCompleted:
                let audio = result.audioData ?? Data()
                let visemes = collector.snapshot()
                let bookmarks = bookmarkCollector.snapshot()
                print("[AzureSDK] Synthesized \(audio.count) bytes + \(visemes.count) visemes + \(bookmarks.count) bookmarks")
                return SynthesisResult(audioData: audio, visemes: visemes, bookmarks: bookmarks)
            case .canceled:
                let details = try SPXSpeechSynthesisCancellationDetails(fromCanceledSynthesisResult: result)
                let reason = details.errorDetails ?? "unknown"
                print("[AzureSDK] Synthesis canceled: \(reason)")
                throw SDKError.synthesisCanceled(reason)
            default:
                throw SDKError.synthesisFailed("result.reason=\(result.reason.rawValue)")
            }
        }.value
    }
    #endif

    // MARK: - Token Fetching

    /// Returns a valid auth token + region, refreshing from the Edge Function
    /// when the cached token is missing or expired.
    private func fetchToken() async throws -> (token: String, region: String) {
        if let cached = cachedToken, cached.isValid {
            return (cached.token, cached.region)
        }

        guard let url = URL(string: "\(supabaseURL)/functions/v1/azure-speech-token") else {
            throw SDKError.badTokenEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SDKError.tokenFetchFailed("status=\(status) body=\(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let region = json["region"] as? String,
              let expiresAt = json["expiresAt"] as? Double else {
            throw SDKError.tokenFetchFailed("malformed response")
        }

        let cached = CachedToken(token: token, region: region, expiresAt: expiresAt)
        cachedToken = cached
        print("[AzureSDK] Token cached for region=\(region), expires in \(Int(expiresAt - Date().timeIntervalSince1970))s")
        return (token, region)
    }

    // MARK: - SSML Builder

    private func buildSSML(segments: [(text: String, emotion: String?)]) -> String {
        let voice = selectedVoice.rawValue
        let supportsStyle = speechStyle != .none && selectedVoice.supportedStyles.contains(speechStyle)
        let rateIsCustom = speechRate != "0%"

        // Emit one bookmark per segment directly before the segment's text.
        // Azure fires bookmarkReached at the audio offset of that exact point.
        var body = ""
        for segment in segments {
            if let emotion = segment.emotion, !emotion.isEmpty {
                body += "<bookmark mark=\"emotion:\(Self.xmlEscape(emotion))\"/>"
            }
            body += Self.xmlEscape(segment.text)
        }

        if supportsStyle {
            body = "<mstts:express-as style=\"\(speechStyle.rawValue)\" styledegree=\"\(styleDegree)\">\(body)</mstts:express-as>"
        }
        if rateIsCustom {
            body = "<prosody rate=\"\(speechRate)\">\(body)</prosody>"
        }

        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="http://www.w3.org/2001/mstts" xml:lang="de-DE">
          <voice name="\(voice)">
            <mstts:viseme type="redlips_front"/>
            \(body)
          </voice>
        </speak>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Settings

    private func loadSettings() {
        if let voiceRaw = UserDefaults.standard.string(forKey: "azure_sdk_voice"),
           let voice = AzureVoice(rawValue: voiceRaw) {
            selectedVoice = voice
        }
        if UserDefaults.standard.object(forKey: "azure_sdk_enabled") != nil {
            isEnabled = UserDefaults.standard.bool(forKey: "azure_sdk_enabled")
        }
        if let rate = UserDefaults.standard.string(forKey: "azure_sdk_rate") {
            speechRate = rate
        }
        if let styleRaw = UserDefaults.standard.string(forKey: "azure_sdk_style"),
           let style = SpeechStyle(rawValue: styleRaw) {
            speechStyle = style
        }
        if UserDefaults.standard.object(forKey: "azure_sdk_style_degree") != nil {
            let d = UserDefaults.standard.double(forKey: "azure_sdk_style_degree")
            styleDegree = (d < 0.01 || d > 2.0) ? 1.0 : d
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(selectedVoice.rawValue, forKey: "azure_sdk_voice")
        UserDefaults.standard.set(isEnabled, forKey: "azure_sdk_enabled")
        UserDefaults.standard.set(speechRate, forKey: "azure_sdk_rate")
        UserDefaults.standard.set(speechStyle.rawValue, forKey: "azure_sdk_style")
        UserDefaults.standard.set(styleDegree, forKey: "azure_sdk_style_degree")
    }

    // MARK: - Errors

    enum SDKError: LocalizedError {
        case sdkNotLinked
        case badTokenEndpoint
        case tokenFetchFailed(String)
        case synthesisCanceled(String)
        case synthesisFailed(String)

        var errorDescription: String? {
            switch self {
            case .sdkNotLinked: return "Azure Speech SDK pod is not linked. Run `pod install`."
            case .badTokenEndpoint: return "Supabase token URL is invalid."
            case .tokenFetchFailed(let m): return "Token fetch failed: \(m)"
            case .synthesisCanceled(let m): return "Synthesis canceled: \(m)"
            case .synthesisFailed(let m): return "Synthesis failed: \(m)"
            }
        }
    }
}

// MARK: - Viseme Collector

/// Thread-safe accumulator for viseme events during SDK callback dispatch.
private final class VisemeCollector: @unchecked Sendable {
    private var events: [VisemeEvent] = []
    private let lock = NSLock()

    func append(_ event: VisemeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [VisemeEvent] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }
}

/// Thread-safe accumulator for bookmark events during SDK callback dispatch.
private final class BookmarkCollector: @unchecked Sendable {
    private var events: [AzureSpeechSDKService.BookmarkEvent] = []
    private let lock = NSLock()

    func append(_ event: AzureSpeechSDKService.BookmarkEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [AzureSpeechSDKService.BookmarkEvent] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }
}
