//
//  ChatViewModel.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Chat View Model

@MainActor
class ChatViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isGenerating: Bool = false
    @Published var isModelLoaded: Bool = false
    @Published var isModelDownloaded: Bool = false
    @Published var modelState: LlamaModelState = .notDownloaded
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    // Voice
    @Published var isListening: Bool = false
    @Published var transcribedText: String = ""
    @Published var isSpeaking: Bool = false

    // Model info
    @Published var currentModel: LlamaModelInfo?
    @Published var recommendedModel: LlamaModelInfo

    // Cloud/Local Mode
    @Published var preferCloudLLM: Bool = true
    @Published var isUsingCloud: Bool = false

    /// Returns true if chat is available (either cloud or local model ready)
    var canChat: Bool {
        // Cloud mode with network connection
        if preferCloudLLM && networkMonitor.isConnected {
            return true
        }
        // Local mode with model loaded
        return isModelLoaded
    }

    // MARK: - Services

    private let llamaService = LlamaService.shared
    private let downloadService = LlamaModelDownloadService.shared
    private let historyStore = ChatHistoryStore.shared
    private let toolCallService = LlamaToolCallService.shared
    private let speechService = SpeechRecognitionService.shared
    private let ttsService = TextToSpeechService.shared
    private let claudeService = ClaudeService.shared
    private let networkMonitor = NetworkMonitor.shared
    private let azureSpeechService = AzureSpeechService.shared
    private let lipSyncService = LipSyncService.shared

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var currentBuddy: Buddy?
    private var systemPrompt: String = ""

    // MARK: - Initialization

    init() {
        recommendedModel = LlamaModelInfo.recommendedModel()

        // Load cloud preference from UserDefaults
        if UserDefaults.standard.object(forKey: "prefer_cloud_llm") != nil {
            preferCloudLLM = UserDefaults.standard.bool(forKey: "prefer_cloud_llm")
        }

        // Setup observers
        setupObservers()

        // Load initial state
        Task {
            await loadInitialState()
        }
    }

    private func setupObservers() {
        // Observe speech service state
        speechService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isListening = state.isListening
            }
            .store(in: &cancellables)

        speechService.$transcribedText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.transcribedText = text
            }
            .store(in: &cancellables)

        // Observe TTS state (local AVSpeech)
        ttsService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                // Only update from local TTS if not using cloud
                if !self.isUsingCloud {
                    self.isSpeaking = state.isSpeaking
                    // Pause ambient baked-gesture scheduler while talking.
                    BuddyGestureService.shared.setSpeaking(state.isSpeaking)
                }
            }
            .store(in: &cancellables)

        // Observe Azure TTS state (cloud)
        azureSpeechService.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self = self else { return }
                // Only update from Azure TTS if using cloud
                if self.isUsingCloud {
                    self.isSpeaking = speaking
                    BuddyGestureService.shared.setSpeaking(speaking)
                }
            }
            .store(in: &cancellables)

        // Observe buddy changes
        NotificationCenter.default.publisher(for: .buddyChanged)
            .compactMap { $0.object as? Buddy }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buddy in
                self?.currentBuddy = buddy
                self?.updateSystemPrompt()
            }
            .store(in: &cancellables)
    }

    private func loadInitialState() async {
        // Load chat history
        let historyMessages = await historyStore.getCurrentMessages()
        messages = historyMessages

        // Check model status
        await checkModelStatus()

        // Load current buddy
        if let buddy = SupabaseService.shared.selectedBuddy {
            currentBuddy = buddy
            updateSystemPrompt()
        }

        // Setup tool call service
        toolCallService.setChatHistoryStore(historyStore)

        // Generate greeting if chat is empty
        if messages.isEmpty {
            await generateGreeting()
        }
    }

    /// Generates an initial greeting from the buddy
    private func generateGreeting() async {
        // Get user info for personalized greeting
        let username = SupabaseService.shared.currentUser?.username ?? "Abenteurer"
        let buddyName = currentBuddy?.name ?? "Jona"
        let greetingPrompt = "Begrüße den Benutzer '\(username)' freundlich. Es ist \(currentTimeOfDay). Halte dich kurz (1-2 Sätze)."

        // Determine if we can use cloud or need local
        let canUseCloud = preferCloudLLM && networkMonitor.isConnected

        if canUseCloud {
            // Use Claude for greeting
            await generateGreetingWithClaude(prompt: greetingPrompt, username: username, buddyName: buddyName)
        } else {
            // Use local model for greeting
            await generateGreetingWithLocalLLM(prompt: greetingPrompt, username: username, buddyName: buddyName)
        }
    }

    /// Generates greeting using Claude (cloud)
    private func generateGreetingWithClaude(prompt: String, username: String, buddyName: String) async {
        isGenerating = true
        isUsingCloud = true

        var assistantMessage = ChatMessage.assistant("", isStreaming: true)
        messages.append(assistantMessage)

        var responseText = ""

        do {
            for try await token in await claudeService.generate(
                prompt: prompt,
                systemPrompt: cloudSystemPrompt,
                conversationHistory: []
            ) {
                responseText += token
                assistantMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers

                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }
            }

            assistantMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers
            assistantMessage.isStreaming = false

            if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                messages[index] = assistantMessage
            }

            await historyStore.addMessage(assistantMessage)
            await speakResponse(responseText.withoutToolCalls)

        } catch {
            print("[ChatViewModel] Cloud greeting failed: \(error), falling back to static")
            // Fallback to static greeting
            assistantMessage.content = "Hallo \(username)! Ich bin \(buddyName), dein AR-Buddy. Wie kann ich dir heute helfen?"
            assistantMessage.isStreaming = false

            if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                messages[index] = assistantMessage
            }
        }

        isGenerating = false
    }

    /// Generates greeting using local LLM (offline)
    private func generateGreetingWithLocalLLM(prompt: String, username: String, buddyName: String) async {
        // Try to load model if not loaded
        if !isModelLoaded && isModelDownloaded {
            await loadModel()
        }

        isUsingCloud = false

        // If model is loaded, generate dynamic greeting
        if isModelLoaded {
            isGenerating = true
            var assistantMessage = ChatMessage.assistant("", isStreaming: true)
            messages.append(assistantMessage)

            var responseText = ""

            do {
                for try await token in await llamaService.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt
                ) {
                    responseText += token
                    assistantMessage.content = responseText

                    if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                        messages[index] = assistantMessage
                    }
                }

                assistantMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers
                assistantMessage.isStreaming = false

                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }

                await historyStore.addMessage(assistantMessage)
                await speakResponse(responseText.withoutToolCalls)

            } catch {
                // Fallback to static greeting on error
                assistantMessage.content = "Hallo \(username)! Ich bin \(buddyName), dein AR-Buddy. Wie kann ich dir heute helfen?"
                assistantMessage.isStreaming = false

                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }
            }

            isGenerating = false
        } else {
            // Static greeting when model not available
            let staticGreeting = ChatMessage.assistant(
                "Hallo \(username)! Ich bin \(buddyName), dein AR-Buddy. Lade das Sprachmodell herunter, damit wir uns richtig unterhalten können!"
            )
            messages.append(staticGreeting)
            await historyStore.addMessage(staticGreeting)
        }
    }

    /// Returns current time of day in German
    private var currentTimeOfDay: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morgen"
        case 12..<17: return "Mittag"
        case 17..<21: return "Abend"
        default: return "Nacht"
        }
    }

    // MARK: - Model Management

    /// Checks the current model download/load status
    func checkModelStatus() async {
        let isCached = await downloadService.isModelCached(for: recommendedModel)
        isModelDownloaded = isCached

        if isCached {
            modelState = .downloaded
        } else {
            modelState = .notDownloaded
        }

        isModelLoaded = await llamaService.isLoaded
        if isModelLoaded {
            modelState = .loaded
            currentModel = await llamaService.currentModel
        }
    }

    /// Downloads the recommended model
    func downloadModel() async {
        guard !isModelDownloaded else { return }

        modelState = .downloading(progress: 0)
        downloadProgress = 0

        do {
            for try await progress in await downloadService.downloadModel(recommendedModel) {
                downloadProgress = progress.progress
                modelState = .downloading(progress: progress.progress)
            }

            isModelDownloaded = true
            modelState = .downloaded
            errorMessage = nil

        } catch {
            modelState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the model into memory
    func loadModel() async {
        guard isModelDownloaded, !isModelLoaded else { return }

        modelState = .loading

        // Use recommended parameters based on device tier
        let tier = DeviceTier.detect()
        let parameters = tier.recommendedParameters

        print("[ChatViewModel] Device Configuration:")
        print("  - RAM: \(String(format: "%.1f", DeviceTier.deviceMemoryGB))GB")
        print("  - Tier: \(tier.displayName) (\(tier.rawValue))")
        print("  - Model: \(recommendedModel.displayName)")
        print("  - Context Length: \(parameters.contextLength)")
        print("  - Max Tokens: \(parameters.maxTokens)")

        do {
            try await llamaService.loadModel(recommendedModel, parameters: parameters)
            isModelLoaded = true
            modelState = .loaded
            currentModel = recommendedModel
            errorMessage = nil

        } catch {
            modelState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Unloads the model from memory
    func unloadModel() async {
        await llamaService.unloadModel()
        isModelLoaded = false
        modelState = .downloaded
        currentModel = nil
    }

    // MARK: - Chat

    /// Sends the current input as a message
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input
        inputText = ""

        // Add user message
        let userMessage = ChatMessage.user(text)
        messages.append(userMessage)
        await historyStore.addMessage(userMessage)

        // Generate response
        await generateResponse(to: text)
    }

    /// Generates a response to the user's message
    private func generateResponse(to userMessage: String) async {
        // Determine if we should use cloud or local
        let shouldUseCloud = preferCloudLLM && networkMonitor.isConnected

        if shouldUseCloud {
            await generateWithClaude(userMessage)
        } else {
            await generateWithLocalLLM(userMessage)
        }
    }

    /// Generates a response using Claude (cloud)
    private func generateWithClaude(_ userMessage: String) async {
        isGenerating = true
        isUsingCloud = true

        // Create placeholder for streaming response
        var assistantMessage = ChatMessage.assistant("", isStreaming: true)
        messages.append(assistantMessage)

        var responseText = ""

        do {
            // Generate with streaming via Claude
            for try await token in await claudeService.generate(
                prompt: userMessage,
                systemPrompt: cloudSystemPrompt,
                conversationHistory: Array(messages.dropLast()) // Exclude the placeholder
            ) {
                responseText += token
                assistantMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers

                // Update the last message
                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }
            }

            // Finalize message
            assistantMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers
            assistantMessage.isStreaming = false
            if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                messages[index] = assistantMessage
            }

            // Save to history
            await historyStore.addMessage(assistantMessage)

            // Speak response with Azure TTS
            await speakResponse(responseText.withoutToolCalls)

        } catch {
            print("[ChatViewModel] Claude generation failed: \(error)")

            // Fallback to local LLM if cloud fails
            if isModelDownloaded {
                print("[ChatViewModel] Falling back to local LLM")
                // Remove the failed placeholder
                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages.remove(at: index)
                }
                await generateWithLocalLLM(userMessage)
                return
            }

            assistantMessage.content = "Entschuldige, es ist ein Fehler aufgetreten: \(error.localizedDescription)"
            assistantMessage.isStreaming = false

            if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                messages[index] = assistantMessage
            }
        }

        isGenerating = false
    }

    /// Generates a response using the local LLM (offline)
    private func generateWithLocalLLM(_ userMessage: String) async {
        isUsingCloud = false

        // Ensure model is loaded
        if !isModelLoaded {
            await loadModel()
            guard isModelLoaded else {
                let errorMsg = ChatMessage.assistant("Entschuldige, ich konnte das Sprachmodell nicht laden. Bitte versuche es später erneut.")
                messages.append(errorMsg)
                return
            }
        }

        isGenerating = true

        // Create placeholder for streaming response
        var assistantMessage = ChatMessage.assistant("", isStreaming: true)
        messages.append(assistantMessage)

        var responseText = ""

        do {
            // Generate with streaming
            for try await token in await llamaService.generate(
                prompt: userMessage,
                systemPrompt: systemPrompt
            ) {
                responseText += token
                assistantMessage.content = responseText

                // Update the last message
                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }
            }

            // Process tool calls if any
            if ToolCall.containsToolCall(responseText) {
                let processed = await toolCallService.processResponse(responseText)

                // Update message with processed text
                assistantMessage.content = processed.displayText.isEmpty
                    ? responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers
                    : processed.displayText.withoutEmotionMarkers.withoutGestureMarkers
                assistantMessage.toolCalls = processed.toolResults
                assistantMessage.isStreaming = false

                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }

                // If tool was called, generate follow-up response
                if processed.hasToolCalls {
                    await generateFollowUp(toolResults: processed.toolResults, originalMessage: userMessage)
                }
            } else {
                // Finalize message
                assistantMessage.isStreaming = false
                if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                    messages[index] = assistantMessage
                }
            }

            // Save to history
            await historyStore.addMessage(assistantMessage)

            // Speak response with local TTS
            await speakResponse(responseText.withoutToolCalls)

        } catch {
            assistantMessage.content = "Entschuldige, es ist ein Fehler aufgetreten: \(error.localizedDescription)"
            assistantMessage.isStreaming = false

            if let index = messages.lastIndex(where: { $0.id == assistantMessage.id }) {
                messages[index] = assistantMessage
            }
        }

        isGenerating = false
    }

    /// Generates a follow-up response after tool execution
    private func generateFollowUp(toolResults: [ToolCallResult], originalMessage: String) async {
        // Build context with tool results
        var context = "Der Benutzer fragte: \(originalMessage)\n\n"
        context += "Tool-Ergebnisse:\n"
        for result in toolResults {
            context += "[\(result.toolName)]: \(result.resultText)\n"
        }
        context += "\nAntworte basierend auf diesen Informationen:"

        // Create new assistant message for follow-up
        var followUpMessage = ChatMessage.assistant("", isStreaming: true)
        messages.append(followUpMessage)

        var responseText = ""

        do {
            for try await token in await llamaService.generate(
                prompt: context,
                systemPrompt: systemPrompt
            ) {
                responseText += token
                followUpMessage.content = responseText

                if let index = messages.lastIndex(where: { $0.id == followUpMessage.id }) {
                    messages[index] = followUpMessage
                }
            }

            followUpMessage.content = responseText.withoutToolCalls.withoutEmotionMarkers.withoutGestureMarkers
            followUpMessage.isStreaming = false

            if let index = messages.lastIndex(where: { $0.id == followUpMessage.id }) {
                messages[index] = followUpMessage
            }

            await historyStore.addMessage(followUpMessage)
            await speakResponse(responseText.withoutToolCalls)

        } catch {
            print("[Chat] Follow-up generation failed: \(error)")
        }
    }

    // MARK: - TTS Helper with Lip Sync

    /// Speaks a response using the appropriate TTS service based on current mode
    /// Also triggers lip sync animation when available
    private func speakResponse(_ text: String) async {
        // One body gesture per response — fired on actual audio start below,
        // not here, so TTS synthesis latency doesn't make the gesture precede
        // speech.
        let gestureMarker = text.firstGestureMarker

        // Strip gesture markers before segmenting for emotions so they don't
        // leak into SSML or viseme generation.
        let cleanedText = text.withoutGestureMarkers

        // Split the response at `[emotion:xxx]` markers. Each segment becomes
        // an SSML bookmark on the Azure SDK path — the bookmarkReached events
        // fire at the exact audio offsets, which we translate into
        // setExpression calls for frame-accurate sync.
        let segments = cleanedText.emotionSegments

        if isUsingCloud && azureSpeechService.isEnabled {
            let result = await azureSpeechService.speakWithLipSync(segments: segments)

            // Start lip sync animation if we have visemes, using the exact audio start time
            if !result.visemes.isEmpty {
                lipSyncService.startAnimation(with: result.visemes, audioStartTime: result.audioStartTime)
                SceneKitLipSyncService.shared.startAnimation(with: result.visemes, audioStartTime: result.audioStartTime)
            } else {
                lipSyncService.startAmplitudeMode()
                SceneKitLipSyncService.shared.startAmplitudeMode()
            }

            scheduleEmotionCues(result.emotionCues, audioStartTime: result.audioStartTime)

            if let marker = gestureMarker {
                let delay = max(0, result.audioStartTime.timeIntervalSinceNow)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    BuddyGestureService.shared.play(marker: marker)
                }
            }

            // Observe speaking state to stop lip sync when done
            observeAzureSpeakingState()
        } else if ttsService.isEnabled {
            // Local TTS doesn't expose word/time callbacks — fall back to the
            // first segment's emotion for the whole utterance. Still better
            // than nothing until we ship a local bookmark equivalent.
            if let first = segments.first(where: { $0.emotion != nil })?.emotion,
               let exp = FacialExpressionService.Expression.fromMarker(first) {
                FacialExpressionService.shared.setExpression(exp, hold: 60.0, fadeIn: 0.15, fadeOut: 0.4)
            }
            lipSyncService.startAmplitudeMode()
            SceneKitLipSyncService.shared.startAmplitudeMode()
            ttsService.speak(text.withoutEmotionMarkers.withoutGestureMarkers)
            if let marker = gestureMarker {
                BuddyGestureService.shared.play(marker: marker)
            }

            observeLocalSpeakingState()
        }
    }

    /// Schedules `setExpression` calls on the main queue timed to the audio
    /// playback. `audioStartTime` is when the first sample hits the speaker;
    /// each cue's `audioOffsetMs` is relative to that. Cues that already lie
    /// in the past (e.g. very first bookmark at offset 0) fire immediately.
    private func scheduleEmotionCues(_ cues: [AzureSpeechService.EmotionCue],
                                     audioStartTime: Date) {
        for cue in cues {
            guard let expression = FacialExpressionService.Expression.fromMarker(cue.emotion) else {
                continue
            }
            let target = audioStartTime.addingTimeInterval(TimeInterval(cue.audioOffsetMs) / 1000.0)
            let delay = max(0, target.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Short hold — next cue (if any) will overwrite it; the
                // Azure-speaking-state observer clears the last one when audio
                // ends. Hold is a safety net for the tail segment.
                if expression == .neutral {
                    FacialExpressionService.shared.clearExpression(fadeOut: 0.25)
                } else {
                    FacialExpressionService.shared.setExpression(
                        expression,
                        hold: 60.0,
                        fadeIn: 0.12,
                        fadeOut: 0.3
                    )
                }
            }
        }
    }

    /// Observes Azure TTS state for lip sync synchronization
    private func observeAzureSpeakingState() {
        // Subscribe to speaking state changes
        azureSpeechService.$isSpeaking
            .dropFirst()  // Skip initial value
            .filter { !$0 }  // Wait for speaking to stop
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lipSyncService.stopAnimation()
                SceneKitLipSyncService.shared.stopAnimation()
                FacialExpressionService.shared.clearExpression()
            }
            .store(in: &cancellables)
    }

    /// Observes local TTS state for lip sync synchronization
    private func observeLocalSpeakingState() {
        ttsService.$state
            .dropFirst()
            .map { $0.isSpeaking }
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lipSyncService.stopAnimation()
                SceneKitLipSyncService.shared.stopAnimation()
                FacialExpressionService.shared.clearExpression()
            }
            .store(in: &cancellables)
    }

    // MARK: - Voice Input

    /// Starts voice input
    func startListening() async {
        do {
            for await text in try await speechService.startListening() {
                inputText = text
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops voice input and sends the message
    func stopListeningAndSend() async {
        let text = speechService.finishListening()
        if !text.isEmpty {
            inputText = text
            await sendMessage()
        }
    }

    /// Cancels voice input
    func cancelListening() {
        speechService.stopListening()
        inputText = ""
    }

    // MARK: - TTS Control

    /// Stops current TTS playback and lip sync
    func stopSpeaking() {
        // Stop lip sync for both renderers
        lipSyncService.stopAnimation()
        SceneKitLipSyncService.shared.stopAnimation()

        if isUsingCloud {
            azureSpeechService.stop()
        } else {
            ttsService.stop()
        }
    }

    /// Toggles TTS enabled state
    func toggleTTS() {
        if isUsingCloud {
            azureSpeechService.isEnabled.toggle()
            azureSpeechService.saveSettings()
        } else {
            ttsService.isEnabled.toggle()
            ttsService.saveSettings()
        }
    }

    // MARK: - Cloud/Local Preference

    /// Saves the cloud LLM preference
    func saveCloudPreference() {
        UserDefaults.standard.set(preferCloudLLM, forKey: "prefer_cloud_llm")
    }

    // MARK: - Conversation Management

    /// Starts a new conversation
    func newConversation() async {
        _ = await historyStore.startNewConversation()
        messages = []
    }

    /// Clears current chat
    func clearChat() async {
        messages = []
        await historyStore.clearAllHistory()
    }

    // MARK: - System Prompt

    private func updateSystemPrompt() {
        // Disable tools for small models (lowMemory tier)
        let tier = DeviceTier.detect()
        let enableTools = tier != .lowMemory

        if !enableTools {
            print("[ChatViewModel] Using simple prompt (no tools) for \(tier.displayName) tier")
        }

        if let buddy = currentBuddy {
            systemPrompt = BuddySystemPrompt.forBuddy(buddy, enableTools: enableTools).prompt
        } else {
            systemPrompt = BuddySystemPrompt(enableTools: enableTools).prompt
        }
    }

    /// System prompt for Claude (cloud) — no tool-call XML instructions,
    /// since those are only for the local Llama model.
    private var cloudSystemPrompt: String {
        if let buddy = currentBuddy {
            return BuddySystemPrompt.simpleForBuddy(buddy).simplePrompt
        }
        return BuddySystemPrompt(enableTools: false).simplePrompt
    }
}
