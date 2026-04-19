//
//  QuestsView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct QuestsView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var mapViewModel: MapViewModel
    @StateObject private var viewModel = QuestsViewModel()
    @ObservedObject private var questService = QuestService.shared
    @State private var showCompletionAlert = false
    @State private var selectedQuizQuest: Quest?
    @State private var groupByPOI = true
    @State private var selectedCompletedEntry: CompletedQuestEntry?
    @State private var isLoadingCompletedEntry = false
    @State private var isLoadingPOIs = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category Picker + Filter Chips
                VStack(spacing: 0) {
                    // Prominent Category Picker with Icons
                    QuestCategoryPicker(selection: $viewModel.selectedCategoryFilter)
                        .onChange(of: viewModel.selectedCategoryFilter) { _, newValue in
                            viewModel.setCategoryFilter(newValue)
                        }

                    // Type filters - only show for POI-Quests
                    if viewModel.selectedCategoryFilter == .poi {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(title: "Alle", isSelected: viewModel.selectedFilter == nil) {
                                    viewModel.setFilter(nil)
                                }

                                // POI quest types: visit, photo, quiz (exclude ar and trivia alias)
                                ForEach([QuestType.visit, .photo, .quiz], id: \.self) { type in
                                    FilterChip(
                                        title: type.displayName,
                                        isSelected: viewModel.selectedFilter == type
                                    ) {
                                        viewModel.setFilter(type)
                                    }
                                }

                                Divider()
                                    .frame(height: 20)
                                    .padding(.horizontal, 4)

                                // Group by POI toggle
                                Button {
                                    withAnimation {
                                        groupByPOI.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: groupByPOI ? "square.grid.2x2" : "list.bullet")
                                        Text(groupByPOI ? "Nach POI" : "Liste")
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.purple.opacity(0.2))
                                    .foregroundColor(.purple)
                                    .cornerRadius(16)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }

                    // Status filters (always visible)
                    HStack(spacing: 8) {
                        ForEach(QuestStatusFilter.allCases, id: \.self) { status in
                            FilterChip(
                                title: status.displayName,
                                isSelected: viewModel.selectedStatusFilter == status,
                                isSmall: true
                            ) {
                                viewModel.setStatusFilter(status)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemGray6))

                // Quest List
                if isLoadingPOIs || mapViewModel.isLoading || questService.isLoading {
                    // Loading State
                    VStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Quests werden geladen...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 12)
                        Spacer()
                    }
                } else if viewModel.filteredQuests.isEmpty {
                    if viewModel.selectedStatusFilter == .completed {
                        VStack {
                            Spacer()
                            ContentUnavailableView(
                                "Keine abgeschlossenen Quests in der Nähe",
                                systemImage: "checkmark.seal",
                                description: Text("Lade zuerst POIs in der Karte oder schau dir alle deine abgeschlossenen Quests an.")
                            )

                            NavigationLink {
                                CompletedQuestsView()
                            } label: {
                                Label("Alle abgeschlossenen Quests", systemImage: "list.star")
                                    .font(.subheadline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(20)
                            }
                            .padding(.top, 4)
                            Spacer()
                        }
                    } else {
                        ContentUnavailableView(
                            "Keine Quests",
                            systemImage: "map",
                            description: Text("Bewege dich in der Karte, um POIs und Quests zu entdecken.")
                        )
                    }
                } else if groupByPOI {
                    // Grouped by POI
                    List {
                        ForEach(viewModel.questsByPOI, id: \.poiId) { group in
                            Section {
                                ForEach(group.quests) { quest in
                                    QuestRowView(
                                        quest: quest,
                                        distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                                        isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation),
                                        isCompleted: viewModel.isQuestCompleted(quest)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleQuestTap(quest)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        questSwipeActions(for: quest)
                                    }
                                }
                            } header: {
                                POIGroupHeader(
                                    poiName: group.poiName,
                                    questCount: group.quests.count,
                                    completedCount: group.completedCount,
                                    statusFilter: viewModel.selectedStatusFilter
                                )
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await refreshQuests()
                    }
                } else {
                    // Flat list
                    List(viewModel.filteredQuests) { quest in
                        QuestRowView(
                            quest: quest,
                            distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                            isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation),
                            isCompleted: viewModel.isQuestCompleted(quest)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleQuestTap(quest)
                        }
                        .swipeActions(edge: .trailing) {
                            questSwipeActions(for: quest)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await refreshQuests()
                    }
                }
            }
            .navigationTitle("Quests")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if let location = locationService.currentLocation {
                                viewModel.sortByDistance(from: location)
                            }
                        } label: {
                            Label("Nach Entfernung", systemImage: "location")
                        }

                        Button {
                            viewModel.updateQuests()
                        } label: {
                            Label("Aktualisieren", systemImage: "arrow.clockwise")
                        }

                        Divider()

                        NavigationLink {
                            CompletedQuestsView()
                        } label: {
                            Label("Alle abgeschlossenen Quests", systemImage: "checkmark.seal")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Quest Status", isPresented: $showCompletionAlert) {
                Button("OK") {
                    viewModel.clearCompletionMessage()
                }
            } message: {
                Text(viewModel.completionMessage ?? "")
            }
            .onAppear {
                viewModel.updateQuests()
                syncPOIProgress()

                // Show loading if quests aren't loaded yet and we have no quests
                if !questService.isQuestsLoaded && viewModel.filteredQuests.isEmpty {
                    isLoadingPOIs = true
                }
            }
            .task {
                // Load POIs if not already loaded (uses pre-fetched cache if available)
                await loadPOIsIfNeeded()
            }
            .onChange(of: locationService.currentLocation) { _, location in
                // Try loading POIs when location becomes available and quests aren't loaded yet
                if !questService.isQuestsLoaded, location != nil {
                    Task {
                        await loadPOIsIfNeeded()
                    }
                }
            }
            .onReceive(mapViewModel.$pois) { pois in
                // Update quests and progress when POIs change
                if !pois.isEmpty {
                    viewModel.updateQuests()
                    syncPOIProgress()
                    isLoadingPOIs = false
                }
            }
            .onReceive(questService.$isQuestsLoaded) { isLoaded in
                // Update loading state when quests finish loading
                if isLoaded {
                    viewModel.updateQuests()
                    isLoadingPOIs = false
                }
            }
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
    }

    /// Refreshes quests - for "completed" filter, only updates without reloading POIs
    private func refreshQuests() async {
        // Don't reload POIs when viewing completed quests (they may be from distant locations)
        if viewModel.selectedStatusFilter == .completed {
            viewModel.updateQuests()
            syncPOIProgress()
        } else {
            // For open/all quests, reload POIs to get latest data
            if let location = locationService.currentLocation {
                await mapViewModel.loadPOIs(near: location)
            }
            viewModel.updateQuests()
            syncPOIProgress()
            if let location = locationService.currentLocation {
                viewModel.sortByDistance(from: location)
            }
        }
    }

    private func handleQuestTap(_ quest: Quest) {
        // If quest is completed, show detail view
        if viewModel.isQuestCompleted(quest) {
            guard let poiId = quest.poiId else { return }
            isLoadingCompletedEntry = true

            Task {
                do {
                    if let entry = try await SupabaseService.shared.fetchCompletedQuestEntry(poiId: poiId) {
                        selectedCompletedEntry = entry
                    }
                } catch {
                    print("Failed to fetch completed quest entry: \(error)")
                }
                isLoadingCompletedEntry = false
            }
        } else {
            // Only open quiz for uncompleted trivia quests
            if quest.type == .trivia {
                selectedQuizQuest = quest
            }
        }
    }

    /// Loads POIs if not already loaded and location is available
    private func loadPOIsIfNeeded() async {
        // Skip if quests are already loaded
        guard !questService.isQuestsLoaded else {
            isLoadingPOIs = false
            return
        }

        guard mapViewModel.pois.isEmpty,
              let location = locationService.currentLocation else {
            return
        }

        isLoadingPOIs = true
        print("[QuestsView] Loading POIs from cache/database...")
        await mapViewModel.loadPOIs(near: location)
        viewModel.updateQuests()
        syncPOIProgress()
        isLoadingPOIs = false
        print("[QuestsView] POIs loaded: \(mapViewModel.pois.count), Quests: \(viewModel.quests.count)")
    }

    private func syncPOIProgress() {
        var progress: [UUID: POIProgress] = [:]

        // First try mapViewModel.pois
        for poi in mapViewModel.pois {
            if let userProgress = poi.userProgress {
                progress[poi.id] = userProgress
            }
        }

        // If mapViewModel.pois is empty, try to get from POIService cache
        if progress.isEmpty {
            Task {
                let cachedPOIs = await POIService.shared.getCachedPOIs(filter: .all)
                var cachedProgress: [UUID: POIProgress] = [:]
                for poi in cachedPOIs {
                    if let userProgress = poi.userProgress {
                        cachedProgress[poi.id] = userProgress
                    }
                }
                if !cachedProgress.isEmpty {
                    viewModel.updatePOIProgress(cachedProgress)
                }
            }
        } else {
            viewModel.updatePOIProgress(progress)
        }
    }

    @ViewBuilder
    private func questSwipeActions(for quest: Quest) -> some View {
        // Only show swipe actions for uncompleted quests
        if !viewModel.isQuestCompleted(quest) && viewModel.isInRange(of: quest, userLocation: locationService.currentLocation) {
            if quest.type == .trivia {
                Button {
                    selectedQuizQuest = quest
                } label: {
                    Label("Quiz starten", systemImage: "questionmark.circle")
                }
                .tint(.blue)
            } else {
                Button {
                    if let location = locationService.currentLocation {
                        _ = viewModel.attemptCompletion(of: quest, userLocation: location)
                        showCompletionAlert = true
                    }
                } label: {
                    Label("Abschließen", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        }
    }
}

// MARK: - POI Group Header

struct POIGroupHeader: View {
    let poiName: String
    let questCount: Int
    let completedCount: Int
    var statusFilter: QuestStatusFilter = .all

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(poiName)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Only show progress text when showing all quests
                if statusFilter == .all {
                    Text("\(completedCount)/\(questCount) abgeschlossen")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(questCount) Quest\(questCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Only show progress indicator when showing all quests
            if statusFilter == .all {
                if completedCount == questCount && questCount > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                } else if completedCount > 0 {
                    // Progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                            .frame(width: 24, height: 24)

                        Circle()
                            .trim(from: 0, to: CGFloat(completedCount) / CGFloat(questCount))
                            .stroke(Color.orange, lineWidth: 3)
                            .frame(width: 24, height: 24)
                            .rotationEffect(.degrees(-90))
                    }
                }
            }
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var isSmall: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSmall ? .caption : .subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, isSmall ? 12 : 16)
                .padding(.vertical, isSmall ? 6 : 8)
                .background(isSelected ? Color.blue : Color.gray.opacity(0.15))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(isSmall ? 16 : 20)
        }
    }
}

// MARK: - Quest Row

struct QuestRowView: View {
    let quest: Quest
    let distance: String?
    let isInRange: Bool
    var isCompleted: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Quest Icon
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green.opacity(0.15) : difficultyColor.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: questIcon)
                    .foregroundColor(isCompleted ? .green : difficultyColor)
                    .font(.title2)

                // Completion/Range Indicator
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                        .background(Circle().fill(Color.white).frame(width: 10, height: 10))
                        .offset(x: 18, y: -18)
                } else if isInRange {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .offset(x: 18, y: -18)
                }
            }

            // Quest Info
            VStack(alignment: .leading, spacing: 4) {
                Text(quest.title)
                    .font(.headline)

                Text(quest.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Label("\(quest.calculatedXPReward) XP", systemImage: "star.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)

                    if let distance = distance {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(distance)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(quest.difficulty.rawValue.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(difficultyColor.opacity(0.15))
                        .foregroundColor(difficultyColor)
                        .cornerRadius(4)
                }
            }

            Spacer()

            if isCompleted {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else if isInRange {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(isCompleted ? 0.8 : 1.0)
    }

    private var questIcon: String {
        switch quest.type {
        case .visit: return "mappin.circle"
        case .photo: return "camera"
        case .ar: return "arkit"
        case .quiz, .trivia: return "questionmark.circle"
        }
    }

    private var difficultyColor: Color {
        switch quest.difficulty {
        case .easy: return .green
        case .medium: return .orange
        case .hard: return .red
        }
    }
}

// MARK: - Quest Type Extension removed - displayName is now defined in Quest.swift

// MARK: - Quest Category Picker

struct QuestCategoryPicker: View {
    @Binding var selection: QuestCategoryFilter

    var body: some View {
        HStack(spacing: 12) {
            CategoryButton(
                title: "POI-Quests",
                icon: "mappin.circle.fill",
                isSelected: selection == .poi,
                color: .orange
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = .poi
                }
            }

            CategoryButton(
                title: "World-Quests",
                icon: "globe.europe.africa.fill",
                isSelected: selection == .world,
                color: .blue
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = .world
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct CategoryButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? color : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    QuestsView()
        .environmentObject(LocationService())
        .environmentObject(MapViewModel())
}
