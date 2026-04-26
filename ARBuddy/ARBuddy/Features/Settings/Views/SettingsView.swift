//
//  SettingsView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAllModelsConfirmation = false
    @State private var isLoggingOut = false
    @StateObject private var llamaViewModel = LlamaSettingsViewModel()
    @StateObject private var cloudViewModel = CloudSettingsViewModel()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("E-Mail", value: supabaseService.currentUser?.email ?? "-")
                LabeledContent("Benutzername", value: supabaseService.currentUser?.username ?? "-")
            }

            Section("AR Buddy") {
                NavigationLink {
                    BuddySelectionView()
                        .environmentObject(supabaseService)
                } label: {
                    HStack {
                        Image(systemName: "figure.stand")
                        Text("Buddy wählen")
                        Spacer()
                        if let buddy = supabaseService.selectedBuddy {
                            Text(buddy.name)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let buddy = supabaseService.selectedBuddy {
                Section("Buddy-Aussehen") {
                    SkinTintRow(buddyName: buddy.name)
                }
            }

            Section("Statistiken") {
                LabeledContent("Level", value: "\(supabaseService.currentUser?.level ?? 1)")
                LabeledContent("Gesamt XP", value: "\(supabaseService.currentUser?.xp ?? 0)")
            }

            // Cloud/Local AI Section
            Section {
                // Cloud vs Local Toggle
                Toggle(isOn: $cloudViewModel.preferCloudLLM) {
                    HStack {
                        Image(systemName: cloudViewModel.preferCloudLLM ? "cloud" : "cpu")
                            .foregroundStyle(cloudViewModel.preferCloudLLM ? .blue : .orange)
                        VStack(alignment: .leading) {
                            Text(cloudViewModel.preferCloudLLM ? "Cloud KI (Claude)" : "Lokale KI")
                            Text(cloudViewModel.preferCloudLLM ?
                                 "Bessere Qualität, benötigt Internet" :
                                 "Offline verfügbar, lokales Modell")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: cloudViewModel.preferCloudLLM) { _, _ in
                    cloudViewModel.savePreferences()
                }

                // Network Status
                HStack {
                    Image(systemName: networkMonitor.connectionType.icon)
                        .foregroundStyle(networkMonitor.isConnected ? .green : .red)
                    Text(networkMonitor.statusDescription)
                    Spacer()
                    if !networkMonitor.isConnected && cloudViewModel.preferCloudLLM {
                        Text("Fallback: Lokal")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("KI-Dienste")
            } footer: {
                if cloudViewModel.preferCloudLLM {
                    Text("Bei aktivierter Cloud-KI wird Claude Haiku für bessere Antworten verwendet. Bei fehlender Internetverbindung wird automatisch auf das lokale Modell umgeschaltet.")
                } else {
                    Text("Das lokale Sprachmodell funktioniert offline, benötigt aber einen Download und mehr Gerätespeicher.")
                }
            }

            // TTS Section
            Section {
                Toggle(isOn: $cloudViewModel.ttsEnabled) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text("Sprachausgabe")
                    }
                }
                .onChange(of: cloudViewModel.ttsEnabled) { _, _ in
                    cloudViewModel.savePreferences()
                }

                // Voice selection (only for Cloud mode)
                if cloudViewModel.preferCloudLLM && cloudViewModel.ttsEnabled {
                    Picker("Stimme", selection: $cloudViewModel.selectedVoice) {
                        ForEach(AzureVoice.recommendedVoices) { voice in
                            HStack {
                                Text(voice.displayName)
                                if voice.isFemale {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                } else {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                }
                            }
                            .tag(voice)
                        }
                    }
                    .onChange(of: cloudViewModel.selectedVoice) { _, _ in
                        cloudViewModel.savePreferences()
                    }

                    // Sprechgeschwindigkeit
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sprechgeschwindigkeit")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            Image(systemName: "tortoise")
                                .foregroundColor(.secondary)
                            Slider(value: $cloudViewModel.speechRate, in: -50...50, step: 10)
                                .onChange(of: cloudViewModel.speechRate) { _, _ in
                                    cloudViewModel.savePreferences()
                                }
                            Image(systemName: "hare")
                                .foregroundColor(.secondary)
                        }

                        Text(cloudViewModel.speechRateLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Sprachstil (nur für Stimmen mit Style-Support)
                    if !cloudViewModel.selectedVoice.supportedStyles.isEmpty {
                        Picker("Sprachstil", selection: $cloudViewModel.speechStyle) {
                            Text("Keine").tag(SpeechStyle.none)
                            ForEach(cloudViewModel.selectedVoice.supportedStyles) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .onChange(of: cloudViewModel.speechStyle) { _, _ in
                            cloudViewModel.savePreferences()
                        }

                        // Intensität (nur wenn Style aktiv)
                        if cloudViewModel.speechStyle != .none {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Intensität")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text("Subtil")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Slider(value: $cloudViewModel.styleDegree, in: 0.5...2.0, step: 0.25)
                                        .onChange(of: cloudViewModel.styleDegree) { _, _ in
                                            cloudViewModel.savePreferences()
                                        }
                                    Text("Stark")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    // Hinweis für HD-Stimmen mit Auto-Emotion
                    if cloudViewModel.selectedVoice.hasAutoEmotion {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.purple)
                            Text("Diese Stimme erkennt Emotionen automatisch aus dem Text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await cloudViewModel.previewVoice()
                        }
                    } label: {
                        HStack {
                            if cloudViewModel.isPreviewingVoice {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Spielt ab...")
                            } else {
                                Image(systemName: "play.circle")
                                Text("Stimme testen")
                            }
                        }
                    }
                    .disabled(cloudViewModel.isPreviewingVoice || !networkMonitor.isConnected)
                }
            } header: {
                Text("Sprachausgabe")
            } footer: {
                if cloudViewModel.preferCloudLLM && cloudViewModel.ttsEnabled {
                    Text("Azure Neural Voices bieten natürlich klingende Sprachausgabe. Bei Offline-Nutzung wird die lokale iOS-Stimme verwendet.")
                }
            }

            // Local Model Section (only show if not using cloud or as fallback info)
            Section("Lokales Sprachmodell") {
                // Device tier info
                HStack {
                    Image(systemName: "cpu")
                    VStack(alignment: .leading) {
                        Text("Geräte-Tier: \(llamaViewModel.deviceTier.displayName)")
                            .font(.subheadline)
                        Text(llamaViewModel.deviceTier.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Recommended model
                HStack {
                    Image(systemName: "brain")
                    VStack(alignment: .leading) {
                        Text(llamaViewModel.recommendedModel.displayName)
                            .font(.subheadline)
                        Text(llamaViewModel.recommendedModel.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(llamaViewModel.recommendedModel.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Model status and actions
                if llamaViewModel.isModelDownloaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Modell heruntergeladen")
                        Spacer()
                        Button("Löschen", role: .destructive) {
                            Task {
                                await llamaViewModel.deleteModel()
                            }
                        }
                        .font(.caption)
                    }
                } else if case .downloading(let progress) = llamaViewModel.modelState {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Wird heruntergeladen...")
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.caption)
                        }
                        ProgressView(value: progress)
                    }
                } else {
                    Button {
                        Task {
                            await llamaViewModel.downloadModel()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Modell herunterladen")
                            if cloudViewModel.preferCloudLLM {
                                Spacer()
                                Text("Für Offline")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Delete all models button
                if llamaViewModel.totalCacheSize > 0 {
                    Button(role: .destructive) {
                        showDeleteAllModelsConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Alle Modelle löschen")
                            Spacer()
                            Text(llamaViewModel.formattedCacheSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showLogoutConfirmation = true
                } label: {
                    HStack {
                        if isLoggingOut {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Abmelden")
                        }
                    }
                }
                .disabled(isLoggingOut)
            }
        }
        .navigationTitle("Einstellungen")
        .confirmationDialog(
            "Möchtest du dich wirklich abmelden?",
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Abmelden", role: .destructive) {
                performLogout()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            "Alle heruntergeladenen Sprachmodelle löschen?",
            isPresented: $showDeleteAllModelsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Alle löschen", role: .destructive) {
                Task {
                    await llamaViewModel.deleteAllModels()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func performLogout() {
        isLoggingOut = true
        Task {
            do {
                try await supabaseService.signOut()
            } catch {
                print("Logout failed: \(error)")
            }
            isLoggingOut = false
        }
    }
}

// MARK: - Llama Settings ViewModel

@MainActor
class LlamaSettingsViewModel: ObservableObject {
    @Published var modelState: LlamaModelState = .notDownloaded
    @Published var isModelDownloaded: Bool = false
    @Published var ttsEnabled: Bool = true
    @Published var totalCacheSize: Int64 = 0

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: totalCacheSize, countStyle: .file)
    }

    let deviceTier: DeviceTier
    let recommendedModel: LlamaModelInfo

    private let downloadService = LlamaModelDownloadService.shared
    private let ttsService = TextToSpeechService.shared

    init() {
        deviceTier = DeviceTier.detect()
        recommendedModel = LlamaModelInfo.recommendedModel()
        ttsEnabled = ttsService.isEnabled

        Task {
            await checkModelStatus()
        }
    }

    func checkModelStatus() async {
        isModelDownloaded = await downloadService.isModelCached(for: recommendedModel)
        modelState = isModelDownloaded ? .downloaded : .notDownloaded
        totalCacheSize = await downloadService.cacheSize()
    }

    func downloadModel() async {
        modelState = .downloading(progress: 0)

        do {
            for try await progress in await downloadService.downloadModel(recommendedModel) {
                modelState = .downloading(progress: progress.progress)
            }
            isModelDownloaded = true
            modelState = .downloaded
        } catch {
            modelState = .error(error.localizedDescription)
        }
    }

    func deleteModel() async {
        do {
            try await downloadService.deleteModel(recommendedModel)
            isModelDownloaded = false
            modelState = .notDownloaded
            totalCacheSize = await downloadService.cacheSize()
        } catch {
            print("Failed to delete model: \(error)")
        }
    }

    func deleteAllModels() async {
        do {
            try await downloadService.clearCache()
            isModelDownloaded = false
            modelState = .notDownloaded
            totalCacheSize = 0
        } catch {
            print("Failed to clear cache: \(error)")
        }
    }

    func saveTTSSettings() {
        ttsService.isEnabled = ttsEnabled
        ttsService.saveSettings()
    }
}

// MARK: - Cloud Settings ViewModel

@MainActor
class CloudSettingsViewModel: ObservableObject {
    @Published var preferCloudLLM: Bool = true
    @Published var ttsEnabled: Bool = true
    @Published var selectedVoice: AzureVoice = .katjaNeural
    @Published var speechRate: Double = 0  // -50 bis +50
    @Published var speechStyle: SpeechStyle = .none
    @Published var styleDegree: Double = 1.0  // 0.5 bis 2.0
    @Published var isPreviewingVoice: Bool = false

    private let azureSpeechService = AzureSpeechService.shared

    var speechRateLabel: String {
        if speechRate == 0 { return "Normal" }
        return speechRate > 0 ? "+\(Int(speechRate))% (schneller)" : "\(Int(speechRate))% (langsamer)"
    }

    init() {
        // Load preferences from UserDefaults
        if UserDefaults.standard.object(forKey: "prefer_cloud_llm") != nil {
            preferCloudLLM = UserDefaults.standard.bool(forKey: "prefer_cloud_llm")
        }

        ttsEnabled = azureSpeechService.isEnabled
        selectedVoice = azureSpeechService.selectedVoice
        speechStyle = azureSpeechService.speechStyle
        styleDegree = azureSpeechService.styleDegree

        // Parse speech rate from string (e.g., "10%" -> 10.0)
        if let rateValue = Double(azureSpeechService.speechRate.replacingOccurrences(of: "%", with: "")) {
            speechRate = rateValue
        }
    }

    func savePreferences() {
        UserDefaults.standard.set(preferCloudLLM, forKey: "prefer_cloud_llm")

        azureSpeechService.isEnabled = ttsEnabled
        azureSpeechService.selectedVoice = selectedVoice
        azureSpeechService.speechRate = "\(Int(speechRate))%"
        azureSpeechService.speechStyle = speechStyle
        azureSpeechService.styleDegree = styleDegree
        azureSpeechService.saveSettings()
    }

    func previewVoice() async {
        isPreviewingVoice = true
        await azureSpeechService.previewVoice()
        isPreviewingVoice = false
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(SupabaseService.shared)
    }
}

// MARK: - Skin Tint

/// ColorPicker + preset swatches for the buddy's skin tint. Writes through
/// to BuddyTintService on every change so the preview refreshes live.
private struct SkinTintRow: View {
    let buddyName: String
    @State private var tint: Color
    @State private var hasTint: Bool

    // A palette from porcelain → very dark. Roughly aligned with Fitzpatrick
    // types I–VI so users have a sensible starting point.
    private let presets: [Color] = [
        Color(red: 1.00, green: 0.94, blue: 0.88),  // porcelain
        Color(red: 0.98, green: 0.87, blue: 0.76),  // light
        Color(red: 0.92, green: 0.78, blue: 0.62),  // fair
        Color(red: 0.80, green: 0.62, blue: 0.47),  // medium
        Color(red: 0.62, green: 0.45, blue: 0.32),  // tan
        Color(red: 0.45, green: 0.30, blue: 0.22),  // brown
        Color(red: 0.30, green: 0.20, blue: 0.15),  // dark
        Color(red: 0.18, green: 0.12, blue: 0.09)   // very dark
    ]

    init(buddyName: String) {
        self.buddyName = buddyName
        let saved = BuddyTintService.shared.loadPersistedTint(for: buddyName)
        _tint = State(initialValue: saved.map { Color($0) } ?? .white)
        _hasTint = State(initialValue: saved != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker("Hautton", selection: $tint, supportsOpacity: false)
                .onChange(of: tint) { _, newValue in
                    let ui = UIColor(newValue)
                    BuddyTintService.shared.savePersistedTint(ui, for: buddyName)
                    BuddyTintService.shared.reapplyPersisted()
                    hasTint = true
                    Task { try? await SupabaseService.shared.updateSkinTint(hex: ui.hexString) }
                }

            HStack(spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    Circle()
                        .fill(preset)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .onTapGesture { tint = preset }
                }
            }

            if hasTint {
                Button("Original wiederherstellen") {
                    BuddyTintService.shared.savePersistedTint(nil, for: buddyName)
                    BuddyTintService.shared.reapplyPersisted()
                    tint = .white
                    hasTint = false
                    Task { try? await SupabaseService.shared.updateSkinTint(hex: nil) }
                }
                .font(.footnote)
                .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

