//
//  AzureSpeechService.swift
//  ARBuddy
//
//  Created by Claude on 14.04.26.
//

import Foundation
import AVFoundation
import Combine
import QuartzCore

// MARK: - Speech Style Definition

enum SpeechStyle: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case cheerful = "cheerful"
    case sad = "sad"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Keine"
        case .cheerful: return "Fröhlich"
        case .sad: return "Traurig"
        }
    }
}

// MARK: - Azure Voice Definition

enum AzureVoice: String, CaseIterable, Identifiable, Codable {
    // German female voices
    case katjaNeural = "de-DE-KatjaNeural"
    case amalaNeural = "de-DE-AmalaNeural"
    case louisa = "de-DE-LouisaNeural"
    case maja = "de-DE-MajaNeural"
    case tanja = "de-DE-TanjaNeural"
    case elke = "de-DE-ElkeNeural"
    case gisela = "de-DE-GiselaNeural"
    case klarissa = "de-DE-KlarissaNeural"

    // German male voices
    case conradNeural = "de-DE-ConradNeural"
    case florian = "de-DE-FlorianMultilingualNeural"
    case bernd = "de-DE-BerndNeural"
    case christoph = "de-DE-ChristophNeural"
    case kasper = "de-DE-KasperNeural"
    case klaus = "de-DE-KlausNeural"
    case ralf = "de-DE-RalfNeural"

    // German HD voices (Dragon HD with auto-emotion)
    // Note: HD voices require lowercase locale (de-de, not de-DE)
    case seraphinaHD = "de-de-Seraphina:DragonHDLatestNeural"
    case florianHD = "de-de-Florian:DragonHDLatestNeural"

    // Austrian voices
    case jonas = "de-AT-JonasNeural"
    case ingrid = "de-AT-IngridNeural"

    // Swiss voices
    case jan = "de-CH-JanNeural"
    case leni = "de-CH-LeniNeural"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .katjaNeural: return "Katja"
        case .amalaNeural: return "Amala"
        case .louisa: return "Louisa"
        case .maja: return "Maja"
        case .tanja: return "Tanja"
        case .elke: return "Elke"
        case .gisela: return "Gisela"
        case .klarissa: return "Klarissa"
        case .conradNeural: return "Conrad"
        case .florian: return "Florian"
        case .bernd: return "Bernd"
        case .christoph: return "Christoph"
        case .kasper: return "Kasper"
        case .klaus: return "Klaus"
        case .ralf: return "Ralf"
        case .seraphinaHD: return "Seraphina HD"
        case .florianHD: return "Florian HD"
        case .jonas: return "Jonas (AT)"
        case .ingrid: return "Ingrid (AT)"
        case .jan: return "Jan (CH)"
        case .leni: return "Leni (CH)"
        }
    }

    var isFemale: Bool {
        switch self {
        case .katjaNeural, .amalaNeural, .louisa, .maja, .tanja, .elke, .gisela, .klarissa, .ingrid, .leni, .seraphinaHD:
            return true
        default:
            return false
        }
    }

    var region: String {
        switch self {
        case .jonas, .ingrid:
            return "Österreich"
        case .jan, .leni:
            return "Schweiz"
        default:
            return "Deutschland"
        }
    }

    /// Returns supported speech styles for this voice
    var supportedStyles: [SpeechStyle] {
        switch self {
        case .conradNeural:
            return [.cheerful, .sad]
        case .seraphinaHD, .florianHD:
            return []  // Auto-emotion, no manual styles
        default:
            return []
        }
    }

    /// Returns true if this voice has automatic emotion detection
    var hasAutoEmotion: Bool {
        switch self {
        case .seraphinaHD, .florianHD:
            return true
        default:
            return false
        }
    }

    /// Returns recommended voices for the buddy character
    static var recommendedVoices: [AzureVoice] {
        [.katjaNeural, .conradNeural, .amalaNeural, .florian, .maja, .kasper, .seraphinaHD, .florianHD]
    }
}

// MARK: - German Phoneme to Viseme Mapper

/// Maps German characters/phonemes to Azure Viseme IDs
/// Azure Viseme IDs:
/// 0 = Silence, 1 = æ/ə/ʌ, 2 = ɑ (wide open), 3 = ɔ (rounded open)
/// 4 = ɛ/ʊ, 5 = ɝ, 6 = i/ɪ (smile), 7 = u/w (pursed)
/// 8 = o, 9 = aʊ, 10 = ɔɪ, 11 = aɪ
/// 12 = h, 13 = ɹ, 14 = l, 15 = s/z
/// 16 = ʃ/tʃ, 17 = θ/ð, 18 = f/v, 19 = d/t/n
/// 20 = k/g/ŋ, 21 = p/b/m (lips closed)
enum GermanPhonemeMapper {
    static func viseme(for char: Character) -> Int {
        switch char.lowercased().first {
        case "a", "ä":
            return 2   // Wide open mouth
        case "e":
            return 4   // Mid-open mouth
        case "i":
            return 6   // Smile position
        case "o", "ö":
            return 8   // Rounded lips
        case "u", "ü":
            return 7   // Pursed lips
        case "m", "p", "b":
            return 21  // Lips closed
        case "f", "v", "w":
            return 18  // Lower lip to teeth
        case "s", "z", "ß":
            return 15  // Teeth visible
        case "l":
            return 14  // Tongue to palate
        case "r":
            return 13  // R sound
        case "n", "t", "d":
            return 19  // Tongue to alveolar ridge
        case "k", "g":
            return 20  // Back of tongue
        case "h":
            return 12  // Open/breathy
        case "j", "y":
            return 6   // Like 'i'
        case "c":
            return 20  // Like 'k' (when not followed by 'h')
        case "q", "x":
            return 20  // Like 'k'
        default:
            return 1   // Default: slightly open
        }
    }
}

// MARK: - Azure Speech Service

@MainActor
class AzureSpeechService: NSObject, ObservableObject {
    static let shared = AzureSpeechService()

    // MARK: - Published Properties

    @Published var selectedVoice: AzureVoice = .katjaNeural
    @Published var isEnabled: Bool = true
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published var speechRate: String = "0%"  // -50% to +50%
    @Published var speechStyle: SpeechStyle = .none
    @Published var styleDegree: Double = 1.0  // 0.01 to 2.0

    /// Toggle to use native SDK mode (real Azure viseme events)
    /// When true, AzureSpeechSDKService is used for lip sync with genuine
    /// phoneme-level timing. Falls back to the REST path automatically if the
    /// SDK framework is not linked or the token fetch fails.
    @Published var useSDKForLipSync: Bool = true

    // MARK: - Private Properties

    private var audioPlayer: AVAudioPlayer?
    private var amplitudeDisplayLink: CADisplayLink?
    private let supabaseURL = "https://ibhaixdirrejsxalntvx.supabase.co"
    private let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImliaGFpeGRpcnJlanN4YWxudHZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg1NjU0NjksImV4cCI6MjA4NDE0MTQ2OX0.966UbEaN19b3leFVi0PR_H1j0F95yAOW8C-oEGHbbyw"

    // MARK: - Initialization

    private override init() {
        super.init()
        loadSettings()
    }

    // MARK: - Public Methods

    /// Speaks the given text using Azure TTS
    /// Returns viseme events if SDK mode is enabled and available
    func speak(_ text: String) async {
        guard isEnabled, !text.isEmpty else { return }

        // Stop any current playback
        stop()

        isLoading = true

        do {
            let audioData = try await fetchAudio(for: text)
            try await playAudio(data: audioData)
        } catch {
            print("[AzureSpeech] Error: \(error)")
        }

        isLoading = false
    }

    /// Result of speakWithLipSync containing visemes and audio start time
    struct LipSyncSpeechResult {
        let visemes: [VisemeEvent]
        let audioStartTime: Date
        let actualAudioDuration: TimeInterval  // Actual duration from AVAudioPlayer
    }

    /// Speaks text with lip sync support
    /// Returns viseme events and audio start time for synchronized lip sync animation
    func speakWithLipSync(_ text: String) async -> LipSyncSpeechResult {
        guard isEnabled, !text.isEmpty else {
            return LipSyncSpeechResult(visemes: [], audioStartTime: Date(), actualAudioDuration: 0)
        }

        // Stop any current playback
        stop()

        isLoading = true

        // If SDK mode is enabled, use the SDK service for real Azure viseme data
        if useSDKForLipSync && AzureSpeechSDKService.shared.isSDKAvailable() {
            let sdkService = AzureSpeechSDKService.shared
            sdkService.selectedVoice = selectedVoice
            sdkService.speechRate = speechRate
            sdkService.speechStyle = speechStyle
            sdkService.styleDegree = styleDegree

            do {
                let result = try await sdkService.synthesize(text)
                let playbackInfo = try await playAudioAndReturnStartTime(data: result.audioData)
                isLoading = false
                print("[AzureSpeech] SDK path: \(result.visemes.count) real visemes, audio \(String(format: "%.2fs", playbackInfo.duration))")
                return LipSyncSpeechResult(
                    visemes: result.visemes,
                    audioStartTime: playbackInfo.startTime,
                    actualAudioDuration: playbackInfo.duration
                )
            } catch {
                print("[AzureSpeech] SDK path failed, falling back to REST: \(error)")
                // Fall through to the server-side path below.
            }
        }

        // Use server-side viseme generation (synchronized to actual audio duration)
        do {
            let result = try await fetchAudioWithVisemes(for: text)
            let playbackInfo = try await playAudioAndReturnStartTime(data: result.audioData)
            isLoading = false

            // Scale visemes to match actual audio duration
            let estimatedDurationMs = Double(result.audioDurationMs)
            let actualDurationMs = playbackInfo.duration * 1000.0

            let scaledVisemes: [VisemeEvent]
            if estimatedDurationMs > 0 && abs(actualDurationMs - estimatedDurationMs) > 50 {
                // Significant duration difference - scale viseme timings
                let scaleFactor = actualDurationMs / estimatedDurationMs
                scaledVisemes = result.visemes.map { viseme in
                    VisemeEvent(
                        visemeId: viseme.visemeId,
                        audioOffsetMilliseconds: Int(Double(viseme.audioOffset * 1000) * scaleFactor)
                    )
                }
                print("[AzureSpeech] Scaled \(result.visemes.count) visemes: estimated=\(Int(estimatedDurationMs))ms actual=\(Int(actualDurationMs))ms scale=\(String(format: "%.2f", scaleFactor))")
            } else {
                scaledVisemes = result.visemes
                print("[AzureSpeech] Using \(result.visemes.count) visemes (duration match: est=\(Int(estimatedDurationMs))ms act=\(Int(actualDurationMs))ms)")
            }

            return LipSyncSpeechResult(
                visemes: scaledVisemes,
                audioStartTime: playbackInfo.startTime,
                actualAudioDuration: playbackInfo.duration
            )
        } catch {
            print("[AzureSpeech] Error fetching with visemes: \(error)")
            // Fallback to simulated visemes
            let visemes = generateSimulatedVisemes(for: text)
            var playbackInfo = AudioPlaybackInfo(startTime: Date(), duration: 0)
            do {
                let audioData = try await fetchAudio(for: text)
                playbackInfo = try await playAudioAndReturnStartTime(data: audioData)
            } catch {
                print("[AzureSpeech] Fallback error: \(error)")
            }
            isLoading = false
            return LipSyncSpeechResult(
                visemes: visemes,
                audioStartTime: playbackInfo.startTime,
                actualAudioDuration: playbackInfo.duration
            )
        }
    }

    /// Response structure for audio + visemes
    private struct AudioWithVisemesResult {
        let audioData: Data
        let visemes: [VisemeEvent]
        let audioDurationMs: Int
    }

    /// Fetches audio with synchronized viseme data from server
    private func fetchAudioWithVisemes(for text: String) async throws -> AudioWithVisemesResult {
        guard let url = URL(string: "\(supabaseURL)/functions/v1/text-to-speech") else {
            throw AzureSpeechError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var requestBody: [String: Any] = [
            "text": text,
            "voiceName": selectedVoice.rawValue,
            "rate": speechRate,
            "includeVisemes": true  // Request viseme data
        ]

        if speechStyle != .none && selectedVoice.supportedStyles.contains(speechStyle) {
            requestBody["style"] = speechStyle.rawValue
            requestBody["styleDegree"] = styleDegree
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("[AzureSpeech] Fetching audio+visemes for \(text.count) chars")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzureSpeechError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw AzureSpeechError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Log raw response for debugging
            let rawString = String(data: data, encoding: .utf8) ?? "(not utf8)"
            print("[AzureSpeech] Failed to parse JSON. Raw response: \(rawString.prefix(500))")
            throw AzureSpeechError.invalidResponse
        }

        // Check for error
        if let error = json["error"] as? String {
            print("[AzureSpeech] Server error: \(error)")
            throw AzureSpeechError.serverError(error)
        }

        // Extract audio (Base64 encoded)
        guard let audioBase64 = json["audio"] as? String else {
            print("[AzureSpeech] No 'audio' field in response. Keys: \(json.keys)")
            throw AzureSpeechError.serverError("No audio field in response")
        }

        print("[AzureSpeech] Audio Base64 length: \(audioBase64.count) chars")

        guard let audioData = Data(base64Encoded: audioBase64) else {
            print("[AzureSpeech] Base64 decode failed. First 100 chars: \(audioBase64.prefix(100))")
            throw AzureSpeechError.serverError("Invalid Base64 audio data")
        }

        print("[AzureSpeech] Decoded audio: \(audioData.count) bytes")

        // Extract visemes
        var visemes: [VisemeEvent] = []
        if let visemeArray = json["visemes"] as? [[String: Any]] {
            for v in visemeArray {
                if let visemeId = v["visemeId"] as? Int,
                   let offset = v["audioOffsetMilliseconds"] as? Int {
                    visemes.append(VisemeEvent(visemeId: visemeId, audioOffsetMilliseconds: offset))
                }
            }
        }

        let audioDurationMs = json["audioDurationMs"] as? Int ?? 0

        print("[AzureSpeech] Received \(audioData.count) bytes audio, \(visemes.count) visemes")

        return AudioWithVisemesResult(
            audioData: audioData,
            visemes: visemes,
            audioDurationMs: audioDurationMs
        )
    }

    /// Parses speechRate string (e.g. "+30%", "-20%", "0%") to a multiplier
    private func speechRateMultiplier() -> Double {
        // Remove % and parse
        let cleanRate = speechRate.replacingOccurrences(of: "%", with: "")
        if let percent = Double(cleanRate) {
            // Convert percent to multiplier: +30% → 1.3, -20% → 0.8
            return 1.0 + (percent / 100.0)
        }
        return 1.0  // Default: normal speed
    }

    /// Generates simulated viseme events based on German phoneme analysis
    /// Used as fallback when SDK visemes are not available
    private func generateSimulatedVisemes(for text: String) -> [VisemeEvent] {
        var events: [VisemeEvent] = []
        var offset: Int = 0

        // Base timing at normal speed (0%)
        // Azure TTS spricht langsamer als zunächst angenommen
        // Empirisch getestet: ~100ms pro Phonem für natürliches Timing
        let baseMsPerChar = 100  // Weiter erhöht (vorher: 75, ursprünglich: 55)
        let baseWordPause = 120  // Längere Pausen zwischen Wörtern

        // Adjust for speech rate setting
        let rateMultiplier = speechRateMultiplier()
        let msPerChar = Int(Double(baseMsPerChar) / rateMultiplier)
        let wordPause = Int(Double(baseWordPause) / rateMultiplier)

        let chars = Array(text.lowercased())
        var i = 0

        while i < chars.count {
            let char = chars[i]

            // Handle whitespace - add silence viseme with pause
            if char == " " {
                events.append(VisemeEvent(visemeId: 0, audioOffsetMilliseconds: offset))
                offset += wordPause  // Short pause between words
                i += 1
                continue
            }

            // Skip non-letter characters
            guard char.isLetter else {
                i += 1
                continue
            }

            // Check for "sch" digraph (3 characters) - spoken as single sound
            if i + 2 < chars.count &&
               chars[i] == "s" && chars[i+1] == "c" && chars[i+2] == "h" {
                events.append(VisemeEvent(visemeId: 16, audioOffsetMilliseconds: offset))
                offset += msPerChar  // Single sound, not 3x duration
                i += 3
                continue
            }

            // Check for "ch" digraph (2 characters) - spoken as single sound
            if i + 1 < chars.count && chars[i] == "c" && chars[i+1] == "h" {
                events.append(VisemeEvent(visemeId: 16, audioOffsetMilliseconds: offset))
                offset += msPerChar  // Single sound
                i += 2
                continue
            }

            // Single character - map to viseme using German phoneme rules
            let visemeId = GermanPhonemeMapper.viseme(for: char)
            events.append(VisemeEvent(visemeId: visemeId, audioOffsetMilliseconds: offset))
            offset += msPerChar
            i += 1
        }

        // End with silence
        events.append(VisemeEvent(visemeId: 0, audioOffsetMilliseconds: offset))
        return events
    }

    /// Stops current playback
    func stop() {
        stopAmplitudeSampling()
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    // MARK: - Amplitude Sampling

    /// Starts sampling the active audio player's average power and forwards the
    /// normalized amplitude to the lip-sync services. This is what drives the
    /// silence-gate that makes pauses between words visible on the 3D buddy.
    private func startAmplitudeSampling() {
        audioPlayer?.isMeteringEnabled = true
        stopAmplitudeSampling()

        let link = CADisplayLink(target: self, selector: #selector(sampleAmplitude))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        amplitudeDisplayLink = link
    }

    private func stopAmplitudeSampling() {
        amplitudeDisplayLink?.invalidate()
        amplitudeDisplayLink = nil
        // Ensure the gate closes when audio stops.
        forwardAmplitudeToLipSync(0)
    }

    @objc private func sampleAmplitude() {
        guard let player = audioPlayer, player.isPlaying else { return }
        player.updateMeters()

        var totalPower: Float = 0
        let channels = max(player.numberOfChannels, 1)
        for i in 0..<channels {
            totalPower += player.averagePower(forChannel: i)
        }
        let avgDb = totalPower / Float(channels)

        // -60 dB is effectively silence for speech; 0 dB is peak.
        let minDb: Float = -60
        let normalized = max(0, min(1, (avgDb - minDb) / abs(minDb)))

        // Debug: log amplitude every ~0.25s so we can see whether pauses in the
        // audio actually register as low amplitude.
        let now = CACurrentMediaTime()
        if now - lastAmplitudeLogTime > 0.25 {
            lastAmplitudeLogTime = now
            print(String(format: "[AzureSpeech] amp=%.2f (%.1f dB)", normalized, avgDb))
        }

        forwardAmplitudeToLipSync(normalized)
    }

    private var lastAmplitudeLogTime: CFTimeInterval = 0

    private func forwardAmplitudeToLipSync(_ amplitude: Float) {
        // CADisplayLink fires on the main run loop, but AzureSpeechService
        // isn't MainActor-isolated. Hop onto the main actor to call the
        // isolated lip-sync singletons safely.
        Task { @MainActor in
            LipSyncService.shared.updateAmplitude(amplitude)
            SceneKitLipSyncService.shared.updateAmplitude(amplitude)
        }
    }

    /// Previews the selected voice with a sample text
    func previewVoice() async {
        let sampleText = "Hallo! Ich bin \(selectedVoice.displayName), dein AR-Buddy Assistent."
        await speak(sampleText)
    }

    // MARK: - Private Methods

    private func fetchAudio(for text: String) async throws -> Data {
        guard let url = URL(string: "\(supabaseURL)/functions/v1/text-to-speech") else {
            throw AzureSpeechError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var requestBody: [String: Any] = [
            "text": text,
            "voiceName": selectedVoice.rawValue,
            "rate": speechRate
        ]

        // Add style parameters if applicable
        if speechStyle != .none && selectedVoice.supportedStyles.contains(speechStyle) {
            requestBody["style"] = speechStyle.rawValue
            requestBody["styleDegree"] = styleDegree
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("[AzureSpeech] Fetching audio for \(text.count) chars with voice: \(selectedVoice.displayName)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AzureSpeechError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw AzureSpeechError.httpError(statusCode: httpResponse.statusCode)
        }

        // Check if response is audio (not JSON error)
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.contains("application/json") {
            // This is an error response
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorJson["error"] as? String {
                throw AzureSpeechError.serverError(errorMessage)
            }
            throw AzureSpeechError.invalidResponse
        }

        print("[AzureSpeech] Received \(data.count) bytes of audio")
        return data
    }

    private func playAudio(data: Data) async throws {
        _ = try await playAudioAndReturnStartTime(data: data)
    }

    /// Result of audio playback start containing timing info
    private struct AudioPlaybackInfo {
        let startTime: Date
        let duration: TimeInterval
    }

    /// Plays audio and returns the exact moment playback started plus actual duration
    /// This is crucial for synchronized lip sync animation
    private func playAudioAndReturnStartTime(data: Data) async throws -> AudioPlaybackInfo {
        print("[AzureSpeech] playAudio called with \(data.count) bytes")

        guard data.count > 0 else {
            print("[AzureSpeech] ERROR: Empty audio data!")
            return AudioPlaybackInfo(startTime: Date(), duration: 0)
        }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.isMeteringEnabled = true
            audioPlayer?.prepareToPlay()

            if let player = audioPlayer {
                let duration = player.duration
                print("[AzureSpeech] AVAudioPlayer created. Duration: \(duration)s, Ready: \(player.prepareToPlay())")
                isSpeaking = true
                // Record the exact moment we start playback - this is the sync point for lip sync
                let startTime = Date()
                let success = player.play()
                startAmplitudeSampling()
                print("[AzureSpeech] play() returned: \(success), startTime: \(startTime)")
                return AudioPlaybackInfo(startTime: startTime, duration: duration)
            } else {
                print("[AzureSpeech] ERROR: audioPlayer is nil after creation")
                return AudioPlaybackInfo(startTime: Date(), duration: 0)
            }
        } catch {
            print("[AzureSpeech] AVAudioPlayer error: \(error)")
            throw error
        }
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        if let voiceRaw = UserDefaults.standard.string(forKey: "azure_speech_voice"),
           let voice = AzureVoice(rawValue: voiceRaw) {
            selectedVoice = voice
        }

        if UserDefaults.standard.object(forKey: "azure_speech_enabled") != nil {
            isEnabled = UserDefaults.standard.bool(forKey: "azure_speech_enabled")
        }

        if let rate = UserDefaults.standard.string(forKey: "azure_speech_rate") {
            speechRate = rate
        }

        if let styleRaw = UserDefaults.standard.string(forKey: "azure_speech_style"),
           let style = SpeechStyle(rawValue: styleRaw) {
            speechStyle = style
        }

        if UserDefaults.standard.object(forKey: "azure_speech_style_degree") != nil {
            styleDegree = UserDefaults.standard.double(forKey: "azure_speech_style_degree")
            // Ensure valid range
            if styleDegree < 0.01 || styleDegree > 2.0 {
                styleDegree = 1.0
            }
        }

        // Default to SDK path (real visemes). Only read UserDefaults when it
        // has been explicitly set, so fresh installs pick up the new default.
        if UserDefaults.standard.object(forKey: "azure_speech_use_sdk") != nil {
            useSDKForLipSync = UserDefaults.standard.bool(forKey: "azure_speech_use_sdk")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(selectedVoice.rawValue, forKey: "azure_speech_voice")
        UserDefaults.standard.set(isEnabled, forKey: "azure_speech_enabled")
        UserDefaults.standard.set(speechRate, forKey: "azure_speech_rate")
        UserDefaults.standard.set(speechStyle.rawValue, forKey: "azure_speech_style")
        UserDefaults.standard.set(styleDegree, forKey: "azure_speech_style_degree")
        UserDefaults.standard.set(useSDKForLipSync, forKey: "azure_speech_use_sdk")
    }
}

// MARK: - Lip Sync Integration Extension

extension AzureSpeechService {
    /// Convenience method to check if lip sync is available
    var isLipSyncAvailable: Bool {
        // Lip sync is available when:
        // 1. SDK mode is enabled and SDK is available (best quality), OR
        // 2. Fallback simulated visemes are used (basic quality)
        return isEnabled
    }

    /// Returns the current lip sync quality level
    var lipSyncQuality: String {
        if useSDKForLipSync && AzureSpeechSDKService.shared.isSDKAvailable() {
            return "Hoch (SDK Viseme)"
        } else {
            return "Basis (Simuliert)"
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AzureSpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopAmplitudeSampling()
            self.isSpeaking = false
            try? AVAudioSession.sharedInstance().setActive(false)
            print("[AzureSpeech] Playback finished (success: \(flag))")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stopAmplitudeSampling()
            self.isSpeaking = false
            print("[AzureSpeech] Decode error: \(error?.localizedDescription ?? "unknown")")
        }
    }
}

// MARK: - Errors

enum AzureSpeechError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige URL"
        case .invalidResponse:
            return "Ungültige Server-Antwort"
        case .httpError(let statusCode):
            return "Server-Fehler: \(statusCode)"
        case .serverError(let message):
            return message
        }
    }
}
