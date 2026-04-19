//
//  TextToSpeechService.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine
import AVFoundation

// MARK: - TTS State

enum TextToSpeechState: Equatable {
    case idle
    case speaking
    case paused

    var isSpeaking: Bool {
        self == .speaking
    }
}

// MARK: - Text To Speech Service

@MainActor
class TextToSpeechService: NSObject, ObservableObject {
    static let shared = TextToSpeechService()

    // MARK: - Published Properties

    @Published private(set) var state: TextToSpeechState = .idle
    @Published private(set) var progress: Double = 0
    @Published var isEnabled: Bool = true
    @Published var speechRate: Float = 0.5  // 0.0 to 1.0
    @Published var speechPitch: Float = 1.0 // 0.5 to 2.0

    // MARK: - Private Properties

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var totalLength: Int = 0
    private var spokenLength: Int = 0

    // Voice settings
    private let voiceLanguage = "de-DE"

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self

        // Load saved settings
        loadSettings()
    }

    // MARK: - Speaking

    /// Speaks the given text
    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }

        // Stop any current speech
        stop()

        // Configure audio session for playback - bail if it fails
        guard configureAudioSession() else {
            print("[TTS] Cannot speak - audio session configuration failed")
            return
        }

        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = mapRate(speechRate)
        utterance.pitchMultiplier = speechPitch
        utterance.volume = 1.0

        // Select German voice
        if let voice = AVSpeechSynthesisVoice(language: voiceLanguage) {
            utterance.voice = voice
        }

        currentUtterance = utterance
        totalLength = text.count
        spokenLength = 0
        progress = 0

        state = .speaking
        synthesizer.speak(utterance)
    }

    /// Stops current speech
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        state = .idle
        progress = 0
        currentUtterance = nil
    }

    /// Pauses current speech
    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        }
    }

    /// Resumes paused speech
    func resume() {
        if state == .paused {
            synthesizer.continueSpeaking()
            state = .speaking
        }
    }

    /// Toggles pause/resume
    func togglePause() {
        if state == .speaking {
            pause()
        } else if state == .paused {
            resume()
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // Use playAndRecord to be compatible with speech recognition
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            return true
        } catch {
            print("[TTS] Failed to configure audio session: \(error)")
            return false
        }
    }

    // MARK: - Rate Mapping

    /// Maps 0-1 slider value to AVSpeechUtterance rate
    private func mapRate(_ value: Float) -> Float {
        // AVSpeechUtterance rate range is roughly 0.0 to 1.0
        // where 0.5 is "normal" speed
        // Map our 0-1 to 0.3-0.7 for usable range
        return 0.3 + (value * 0.4)
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        if let rate = UserDefaults.standard.object(forKey: "tts_speech_rate") as? Float {
            speechRate = rate
        }
        if let pitch = UserDefaults.standard.object(forKey: "tts_speech_pitch") as? Float {
            speechPitch = pitch
        }
        // Default to DISABLED to avoid audio conflicts
        if UserDefaults.standard.object(forKey: "tts_enabled") != nil {
            isEnabled = UserDefaults.standard.bool(forKey: "tts_enabled")
        } else {
            isEnabled = false
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(speechRate, forKey: "tts_speech_rate")
        UserDefaults.standard.set(speechPitch, forKey: "tts_speech_pitch")
        UserDefaults.standard.set(isEnabled, forKey: "tts_enabled")
    }

    // MARK: - Available Voices

    /// Returns available German voices
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.starts(with: "de") }
    }

    /// Checks if TTS is available
    var isAvailable: Bool {
        !availableVoices.isEmpty
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TextToSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            state = .speaking
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            state = .idle
            progress = 1.0
            currentUtterance = nil

            // Deactivate audio session
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            state = .idle
            progress = 0
            currentUtterance = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            spokenLength = characterRange.location + characterRange.length
            if totalLength > 0 {
                progress = Double(spokenLength) / Double(totalLength)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            state = .paused
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            state = .speaking
        }
    }
}
