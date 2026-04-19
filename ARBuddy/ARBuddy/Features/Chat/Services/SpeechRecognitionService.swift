//
//  SpeechRecognitionService.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine
import Speech
import AVFoundation

// MARK: - Speech Recognition State

enum SpeechRecognitionState: Equatable {
    case idle
    case requesting
    case ready
    case listening
    case processing
    case error(String)

    var isListening: Bool {
        self == .listening
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Bereit"
        case .requesting:
            return "Berechtigung wird angefragt..."
        case .ready:
            return "Tippen zum Sprechen"
        case .listening:
            return "Ich höre zu..."
        case .processing:
            return "Verarbeite..."
        case .error(let message):
            return "Fehler: \(message)"
        }
    }
}

// MARK: - Speech Recognition Errors

enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case notAvailable
    case audioSessionFailed
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Spracherkennung nicht autorisiert"
        case .notAvailable:
            return "Spracherkennung nicht verfügbar"
        case .audioSessionFailed:
            return "Audio-Session konnte nicht gestartet werden"
        case .recognitionFailed(let reason):
            return "Erkennung fehlgeschlagen: \(reason)"
        }
    }
}

// MARK: - Speech Recognition Service

@MainActor
class SpeechRecognitionService: ObservableObject {
    static let shared = SpeechRecognitionService()

    // MARK: - Published Properties

    @Published private(set) var state: SpeechRecognitionState = .idle
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var isAuthorized: Bool = false

    // MARK: - Private Properties

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // MARK: - Initialization

    private init() {
        // Initialize with German locale
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    }

    // MARK: - Authorization

    /// Requests speech recognition authorization
    func requestAuthorization() async -> Bool {
        state = .requesting

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    switch status {
                    case .authorized:
                        self?.isAuthorized = true
                        self?.state = .ready
                        continuation.resume(returning: true)
                    case .denied, .restricted, .notDetermined:
                        self?.isAuthorized = false
                        self?.state = .error("Nicht autorisiert")
                        continuation.resume(returning: false)
                    @unknown default:
                        self?.isAuthorized = false
                        self?.state = .error("Unbekannter Status")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    /// Checks current authorization status
    func checkAuthorization() -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        isAuthorized = status == .authorized
        if isAuthorized {
            state = .ready
        }
        return isAuthorized
    }

    // MARK: - Recording

    /// Starts speech recognition
    func startListening() async throws -> AsyncStream<String> {
        if !isAuthorized {
            let authorized = await requestAuthorization()
            if !authorized {
                throw SpeechRecognitionError.notAuthorized
            }
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.notAvailable
        }

        // Stop any existing task first
        stopListening()

        transcribedText = ""

        // Configure audio session BEFORE accessing audio engine
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechRecognitionError.audioSessionFailed
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechRecognitionError.recognitionFailed("Request konnte nicht erstellt werden")
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation

        // Setup audio input - get format AFTER audio session is configured
        let inputNode = audioEngine.inputNode

        // Get the native format from the input node
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate the format
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            throw SpeechRecognitionError.audioSessionFailed
        }

        state = .listening

        return AsyncStream { continuation in
            // Start recognition task
            self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    if let result = result {
                        let text = result.bestTranscription.formattedString
                        self?.transcribedText = text
                        continuation.yield(text)

                        if result.isFinal {
                            self?.state = .processing
                            continuation.finish()
                        }
                    }

                    if let error = error {
                        self?.state = .error(error.localizedDescription)
                        continuation.finish()
                    }
                }
            }

            // Install audio tap with validated format
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            // Prepare and start audio engine
            self.audioEngine.prepare()

            do {
                try self.audioEngine.start()
            } catch {
                Task { @MainActor in
                    self.state = .error("Audio konnte nicht gestartet werden: \(error.localizedDescription)")
                }
                continuation.finish()
                return
            }

            // Handle cancellation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stopListening()
                }
            }
        }
    }

    /// Stops speech recognition
    func stopListening() {
        // Stop in correct order
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        // Remove tap safely
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        if state == .listening {
            state = .ready
        }

        // Reset audio session
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Returns the final transcribed text and stops listening
    func finishListening() -> String {
        let result = transcribedText
        stopListening()
        state = .ready
        return result
    }

    // MARK: - Utilities

    /// Checks if speech recognition is available on this device
    var isAvailable: Bool {
        speechRecognizer?.isAvailable ?? false
    }
}
