//
//  SynchronizedAudioPlayer.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Synchronized Audio Player

/// Audio player with precise timing for lip sync synchronization
/// Provides callbacks for audio progress and completion
@MainActor
class SynchronizedAudioPlayer: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var amplitude: Float = 0

    // MARK: - Callbacks

    var onPlaybackStarted: (() -> Void)?
    var onPlaybackProgress: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onAmplitudeUpdate: ((Float) -> Void)?

    // MARK: - Private Properties

    private var audioPlayer: AVAudioPlayer?
    private var displayLink: CADisplayLink?
    private var startTime: Date?

    // For amplitude metering
    private var isMeteringEnabled: Bool = false

    // MARK: - Public Methods

    /// Loads audio data and prepares for playback
    func load(data: Data) throws {
        stop()

        audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        duration = audioPlayer?.duration ?? 0

        // Enable metering for amplitude-based lip sync fallback
        audioPlayer?.isMeteringEnabled = true
        isMeteringEnabled = true
    }

    /// Starts playback and returns the start time for synchronization
    @discardableResult
    func play() -> Date {
        guard let player = audioPlayer else {
            return Date()
        }

        // Configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("[SyncAudio] Audio session error: \(error)")
        }

        startTime = Date()
        isPlaying = true
        player.play()

        startProgressUpdates()
        onPlaybackStarted?()

        return startTime!
    }

    /// Plays audio data directly (convenience method)
    @discardableResult
    func play(data: Data) async throws -> Date {
        try load(data: data)
        return play()
    }

    /// Stops playback
    func stop() {
        stopProgressUpdates()

        audioPlayer?.stop()
        audioPlayer = nil

        isPlaying = false
        currentTime = 0
        amplitude = 0
        startTime = nil

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Pauses playback
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressUpdates()
    }

    /// Resumes playback
    func resume() {
        guard audioPlayer != nil else { return }
        audioPlayer?.play()
        isPlaying = true
        startProgressUpdates()
    }

    /// Returns time elapsed since playback started
    var elapsedTime: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Progress Updates

    private func startProgressUpdates() {
        guard displayLink == nil else { return }

        displayLink = CADisplayLink(target: self, selector: #selector(updateProgress))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopProgressUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateProgress() {
        guard let player = audioPlayer, isPlaying else { return }

        currentTime = player.currentTime
        onPlaybackProgress?(currentTime)

        // Update amplitude for fallback lip sync
        if isMeteringEnabled {
            player.updateMeters()

            // Get average power across channels (in dB, typically -160 to 0)
            var totalPower: Float = 0
            let channels = player.numberOfChannels
            for i in 0..<channels {
                totalPower += player.averagePower(forChannel: i)
            }
            let averagePower = totalPower / Float(max(channels, 1))

            // Convert dB to linear amplitude (0.0 to 1.0)
            // -160 dB = silence, 0 dB = max
            let minDb: Float = -60  // Practical minimum
            let normalizedPower = max(0, (averagePower - minDb) / abs(minDb))
            amplitude = min(normalizedPower, 1.0)

            onAmplitudeUpdate?(amplitude)
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SynchronizedAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopProgressUpdates()
            self.isPlaying = false
            self.onPlaybackEnded?()

            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.stopProgressUpdates()
            self.isPlaying = false
            print("[SyncAudio] Decode error: \(error?.localizedDescription ?? "unknown")")
            self.onPlaybackEnded?()
        }
    }
}

// MARK: - Lip Sync Coordinator

/// Coordinates audio playback with lip sync animation
@MainActor
class LipSyncCoordinator: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var isActive: Bool = false

    // MARK: - Services

    private let audioPlayer = SynchronizedAudioPlayer()
    private let lipSyncService = LipSyncService.shared

    // MARK: - Private Properties

    private var visemeEvents: [VisemeEvent] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        setupBindings()
    }

    private func setupBindings() {
        // Observe audio player state
        audioPlayer.$isPlaying
            .sink { [weak self] playing in
                self?.isActive = playing
            }
            .store(in: &cancellables)

        // Forward amplitude to lip sync service for fallback mode
        audioPlayer.onAmplitudeUpdate = { [weak self] amplitude in
            self?.lipSyncService.updateAmplitude(amplitude)
        }

        // Stop lip sync when audio ends
        audioPlayer.onPlaybackEnded = { [weak self] in
            self?.lipSyncService.stopAnimation()
        }
    }

    // MARK: - Public Methods

    /// Starts synchronized lip sync with audio playback
    /// - Parameters:
    ///   - audioData: The audio data to play
    ///   - visemes: Viseme events from Azure SDK (or simulated)
    func startLipSync(audioData: Data, visemes: [VisemeEvent]) async throws {
        self.visemeEvents = visemes

        // Load and prepare audio
        try audioPlayer.load(data: audioData)

        // Start audio playback and get the exact start time
        let audioStartTime = audioPlayer.play()

        // Start lip sync animation with visemes, using the exact audio start time
        lipSyncService.startAnimation(with: visemes, audioStartTime: audioStartTime)
    }

    /// Starts amplitude-based lip sync without viseme data
    func startAmplitudeLipSync(audioData: Data) async throws {
        try audioPlayer.load(data: audioData)

        // Start amplitude-based animation
        lipSyncService.startAmplitudeMode()

        audioPlayer.play()
    }

    /// Stops both audio and lip sync
    func stop() {
        audioPlayer.stop()
        lipSyncService.stopAnimation()
    }

    /// Returns current playback progress (0.0 to 1.0)
    var progress: Float {
        guard audioPlayer.duration > 0 else { return 0 }
        return Float(audioPlayer.currentTime / audioPlayer.duration)
    }

    /// Returns current audio time
    var currentTime: TimeInterval {
        audioPlayer.currentTime
    }
}
