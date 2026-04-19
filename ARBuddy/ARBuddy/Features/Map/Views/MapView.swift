//
//  MapView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var viewModel: MapViewModel
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    // Available categories (excluding food and shop)
    private static let availableCategories: [POICategory] = [.landmark, .culture, .entertainment, .nature, .other]
    // Default selection (all except nature)
    @State private var selectedCategories: Set<POICategory> = [.landmark, .culture, .entertainment, .other]
    @State private var selectedFilter: POIProgressFilter = .all

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $position) {
                    UserAnnotation()

                    ForEach(viewModel.filteredPOIs(categories: selectedCategories, progressFilter: selectedFilter)) { poi in
                        Annotation(poi.name, coordinate: poi.coordinate) {
                            POIMarkerView(
                                poi: poi,
                                isSelected: viewModel.selectedPOI?.id == poi.id,
                                quests: QuestService.shared.quests(for: poi.id)
                            )
                            .onTapGesture {
                                withAnimation {
                                    viewModel.selectedPOI = poi
                                }
                            }
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onChange(of: locationService.currentLocation) { _, newLocation in
                    if let location = newLocation {
                        Task {
                            await viewModel.loadPOIs(near: location)
                        }
                    }
                }

                VStack {
                    // Category and Progress Filter
                    VStack(spacing: 8) {
                        // Category Filter (Multi-Select)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.availableCategories, id: \.self) { category in
                                    CategoryChip(
                                        title: category.displayName,
                                        icon: category.iconName,
                                        isSelected: selectedCategories.contains(category)
                                    ) {
                                        // Toggle category
                                        if selectedCategories.contains(category) {
                                            selectedCategories.remove(category)
                                        } else {
                                            selectedCategories.insert(category)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }

                        // Progress Filter (only show when logged in)
                        if SupabaseService.shared.isAuthenticated {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(POIProgressFilter.allCases, id: \.self) { filter in
                                        ProgressFilterChip(
                                            filter: filter,
                                            isSelected: selectedFilter == filter
                                        ) {
                                            selectedFilter = filter
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)

                    Spacer()

                    // Loading Indicator
                    if viewModel.isLoading {
                        HStack {
                            ProgressView()
                            Text("POIs werden geladen...")
                                .font(.caption)
                        }
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(8)
                    }

                    // Error Message
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(8)
                    }

                    // POI Detail Card
                    if let poi = viewModel.selectedPOI {
                        POIDetailCard(
                            poi: poi,
                            distance: viewModel.distance(to: poi, from: locationService.currentLocation),
                            quests: QuestService.shared.quests(for: poi.id)
                        ) {
                            withAnimation {
                                viewModel.selectedPOI = nil
                            }
                        }
                        .padding()
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationTitle("Karte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        if let location = locationService.currentLocation {
                            Task {
                                // Force refresh: call Geoapify to discover new POIs
                                await viewModel.refreshPOIsFromAPI(near: location, radius: 5000)
                            }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .onAppear {
                locationService.requestPermission()
                // POIs laden falls Location bereits verfügbar
                if let location = locationService.currentLocation {
                    Task {
                        await viewModel.loadPOIs(near: location)
                    }
                }
            }
        }
    }
}

// MARK: - Progress Filter

enum POIProgressFilter: String, CaseIterable {
    case all = "Alle"
    case completed = "Erledigt"
    case inProgress = "Gestartet"
    case notStarted = "Offen"

    var icon: String {
        switch self {
        case .all: return "circle.grid.2x2"
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.lefthalf.filled"
        case .notStarted: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .all: return .blue
        case .completed: return .green
        case .inProgress: return .orange
        case .notStarted: return .gray
        }
    }
}

// MARK: - Progress Filter Chip

struct ProgressFilterChip: View {
    let filter: POIProgressFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.caption)
                Text(filter.rawValue)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? filter.color : Color.gray.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color.gray.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
    }
}

// MARK: - POI Marker

struct POIMarkerView: View {
    let poi: POI
    let isSelected: Bool
    let quests: [POIQuest]

    // Verfügbare Quest-Typen (dedupliziert)
    private var availableQuestTypes: Set<QuestType> {
        Set(quests.map { $0.questType })
    }

    // Anzahl abgeschlossener Quests basierend auf verfügbaren Typen
    private var completedQuestCount: Int {
        guard let progress = poi.userProgress else { return 0 }
        var count = 0
        for questType in availableQuestTypes {
            switch questType {
            case .visit: if progress.visitCompleted { count += 1 }
            case .photo: if progress.photoCompleted { count += 1 }
            case .quiz, .trivia: if progress.quizCompleted { count += 1 }
            case .ar: if progress.arCompleted { count += 1 }
            }
        }
        return count
    }

    // Fortschritt als Dezimalzahl (0.0 - 1.0)
    private var progressFraction: Double {
        guard !availableQuestTypes.isEmpty else { return 0 }
        return Double(completedQuestCount) / Double(availableQuestTypes.count)
    }

    // Ist der POI vollständig abgeschlossen?
    private var isFullyCompleted: Bool {
        !availableQuestTypes.isEmpty && completedQuestCount == availableQuestTypes.count
    }

    private var progressColor: Color {
        if isFullyCompleted { return .green }
        if completedQuestCount > 0 { return .orange }
        return .blue
    }

    private var hasProgress: Bool {
        completedQuestCount > 0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? progressColor : Color.white)
                .frame(width: 44, height: 44)
                .shadow(radius: 3)

            // Progress ring - zeigt Fortschritt als teilweisen Kreis
            if hasProgress {
                // Hintergrund-Ring (grau, zeigt den "leeren" Teil)
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: 48, height: 48)

                // Fortschritts-Ring (orange/grün, zeigt den "gefüllten" Teil)
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(progressColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90)) // Start oben statt rechts
            }

            Image(systemName: poi.category.iconName)
                .foregroundColor(isSelected ? .white : progressColor)
                .font(.system(size: 18))

            // Completion badge
            if hasProgress {
                Image(systemName: isFullyCompleted ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                    .foregroundColor(progressColor)
                    .font(.caption)
                    .background(Circle().fill(.white).frame(width: 16, height: 16))
                    .offset(x: 16, y: -16)
            }

            // Quest Badge (only if no progress)
            if !hasProgress && !quests.isEmpty {
                Text("\(quests.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.orange)
                    .clipShape(Circle())
                    .offset(x: 14, y: -14)
            }
        }
    }
}

// MARK: - POI Detail Card

struct POIDetailCard: View {
    let poi: POI
    let distance: String?
    let quests: [POIQuest]  // Tatsächliche Quests statt questCount
    let onDismiss: () -> Void

    // Computed property für verfügbare Quest-Typen (dedupliziert und sortiert)
    private var availableQuestTypes: [QuestType] {
        Array(Set(quests.map { $0.questType })).sorted { $0.rawValue < $1.rawValue }
    }

    // Anzahl der abgeschlossenen Quests basierend auf verfügbaren Typen
    private func completedCount(progress: POIProgress) -> Int {
        var count = 0
        for questType in availableQuestTypes {
            switch questType {
            case .visit: if progress.visitCompleted { count += 1 }
            case .photo: if progress.photoCompleted { count += 1 }
            case .quiz, .trivia: if progress.quizCompleted { count += 1 }
            case .ar: if progress.arCompleted { count += 1 }
            }
        }
        return count
    }

    // Progress percentage basierend auf verfügbaren Quests
    private func progressPercentage(progress: POIProgress) -> Double {
        guard !quests.isEmpty else { return 0 }
        return Double(completedCount(progress: progress)) / Double(availableQuestTypes.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: poi.category.iconName)
                    .foregroundColor(.blue)
                    .font(.title2)

                VStack(alignment: .leading) {
                    Text(poi.name)
                        .font(.headline)

                    if let distance = distance {
                        Text(distance + " entfernt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
            }

            Text(poi.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)

            // Quest Status - zeigt verfügbare Quests und Fortschritt
            if !quests.isEmpty {
                let progress = poi.userProgress
                let completed = progress.map { completedCount(progress: $0) } ?? 0
                let total = availableQuestTypes.count
                let isFullyCompleted = completed == total && total > 0

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fortschritt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(completed)/\(total) Quests")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                        .tint(isFullyCompleted ? .green : .orange)

                    // Quest completion icons - nur für verfügbare Quest-Typen
                    HStack(spacing: 8) {
                        ForEach(availableQuestTypes, id: \.rawValue) { questType in
                            switch questType {
                            case .visit:
                                QuestCompletionIcon(type: .visit, isCompleted: progress?.visitCompleted ?? false)
                            case .photo:
                                QuestCompletionIcon(type: .photo, isCompleted: progress?.photoCompleted ?? false)
                            case .quiz, .trivia:
                                QuestCompletionIcon(type: .trivia, isCompleted: progress?.quizCompleted ?? false)
                            case .ar:
                                QuestCompletionIcon(type: .ar, isCompleted: progress?.arCompleted ?? false)
                            }
                        }
                    }
                }
            }

            HStack {
                Label(poi.category.displayName, systemImage: poi.category.iconName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if !quests.isEmpty {
                    Label("\(quests.count) Quest\(quests.count == 1 ? "" : "s")", systemImage: "list.bullet")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !quests.isEmpty {
                NavigationLink(destination: POIQuestsView(poi: poi)) {
                    Text("Quests anzeigen")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
    }
}

// MARK: - Quest Completion Icon

struct QuestCompletionIcon: View {
    let type: QuestType
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: iconName)
                .foregroundColor(isCompleted ? .green : .gray.opacity(0.5))
                .font(.caption)
            Text(type.displayName)
                .font(.caption2)
                .foregroundColor(isCompleted ? .primary : .secondary)
        }
    }

    private var iconName: String {
        switch type {
        case .visit: return isCompleted ? "mappin.circle.fill" : "mappin.circle"
        case .photo: return isCompleted ? "camera.fill" : "camera"
        case .ar: return "arkit"
        case .quiz, .trivia: return isCompleted ? "checkmark.circle.fill" : "questionmark.circle"
        }
    }
}

// MARK: - POI Quests View

struct POIQuestsView: View {
    let poi: POI
    @StateObject private var viewModel = QuestsViewModel()
    @EnvironmentObject var locationService: LocationService
    @State private var selectedQuizQuest: Quest?
    @State private var selectedCompletedEntry: CompletedQuestEntry?
    @State private var isLoadingCompletedEntry = false

    private var quests: [Quest] {
        QuestService.shared.legacyQuests(for: poi.id)
    }

    var body: some View {
        List {
            // POI Info Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: poi.category.iconName)
                            .foregroundColor(.blue)
                        Text(poi.name)
                            .font(.headline)
                    }

                    if let address = poi.formattedAddress {
                        Text(address)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let progress = poi.userProgress, !quests.isEmpty {
                        let totalQuests = quests.count
                        let completedQuests = countCompletedQuests(progress: progress)
                        ProgressView(value: Double(completedQuests) / Double(totalQuests))
                            .tint(completedQuests == totalQuests ? .green : .orange)
                        Text("\(completedQuests)/\(totalQuests) Quests abgeschlossen")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Quests Section
            Section("Quests") {
                ForEach(quests) { quest in
                    let isCompleted = isQuestCompleted(quest)
                    QuestRowView(
                        quest: quest,
                        distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                        isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation),
                        isCompleted: isCompleted
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleQuestTap(quest, isCompleted: isCompleted)
                    }
                }
            }
        }
        .navigationTitle(poi.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedQuizQuest) { quest in
            QuizView(
                poiId: quest.poiId,
                poiName: quest.title,
                category: "Sehenswürdigkeit",
                xpPerQuestion: quest.calculatedXPReward / 5
            )
        }
        .sheet(item: $selectedCompletedEntry) { entry in
            NavigationStack {
                CompletedQuestDetailView(entry: entry)
            }
        }
        .overlay {
            if isLoadingCompletedEntry {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        }
    }

    private func isQuestCompleted(_ quest: Quest) -> Bool {
        guard let progress = poi.userProgress else { return false }
        switch quest.type {
        case .visit: return progress.visitCompleted
        case .photo: return progress.photoCompleted
        case .ar: return progress.arCompleted
        case .quiz, .trivia: return progress.quizCompleted
        }
    }

    // Zählt abgeschlossene Quests basierend auf den tatsächlich verfügbaren Quest-Typen
    private func countCompletedQuests(progress: POIProgress) -> Int {
        let questTypes = Set(quests.map { $0.type })
        var count = 0
        for questType in questTypes {
            switch questType {
            case .visit: if progress.visitCompleted { count += 1 }
            case .photo: if progress.photoCompleted { count += 1 }
            case .quiz, .trivia: if progress.quizCompleted { count += 1 }
            case .ar: if progress.arCompleted { count += 1 }
            }
        }
        return count
    }

    private func handleQuestTap(_ quest: Quest, isCompleted: Bool) {
        if isCompleted {
            // Show completed quest detail
            isLoadingCompletedEntry = true
            Task {
                do {
                    if let entry = try await SupabaseService.shared.fetchCompletedQuestEntry(poiId: poi.id) {
                        selectedCompletedEntry = entry
                    }
                } catch {
                    print("Failed to fetch completed quest entry: \(error)")
                }
                isLoadingCompletedEntry = false
            }
        } else {
            // Only open quiz for uncompleted quiz/trivia quests
            if quest.type == .quiz || quest.type == .trivia {
                selectedQuizQuest = quest
            }
        }
    }
}

// MARK: - POI Category Extension

extension POICategory {
    var displayName: String {
        switch self {
        case .landmark: return "Sehenswürdigkeiten"
        case .nature: return "Natur"
        case .culture: return "Kultur"
        case .food: return "Essen"
        case .shop: return "Shops"
        case .entertainment: return "Unterhaltung"
        case .other: return "Sonstiges"
        }
    }
}

#Preview {
    MapTabView()
        .environmentObject(LocationService())
        .environmentObject(MapViewModel())
}
