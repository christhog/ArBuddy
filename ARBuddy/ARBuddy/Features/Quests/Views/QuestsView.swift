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
    @State private var showCompletionAlert = false
    @State private var selectedQuizQuest: Quest?
    @State private var groupByPOI = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "Alle", isSelected: viewModel.selectedFilter == nil) {
                            viewModel.setFilter(nil)
                        }

                        ForEach(QuestType.allCases, id: \.self) { type in
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
                .background(Color(.systemGray6))

                // Quest List
                if viewModel.filteredQuests.isEmpty {
                    ContentUnavailableView(
                        "Keine Quests",
                        systemImage: "map",
                        description: Text("Bewege dich in der Karte, um POIs und Quests zu entdecken.")
                    )
                } else if groupByPOI {
                    // Grouped by POI
                    List {
                        ForEach(viewModel.questsByPOI, id: \.poiId) { group in
                            Section {
                                ForEach(group.quests) { quest in
                                    QuestRowView(
                                        quest: quest,
                                        distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                                        isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if quest.type == .trivia {
                                            selectedQuizQuest = quest
                                        }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        questSwipeActions(for: quest)
                                    }
                                }
                            } header: {
                                POIGroupHeader(
                                    poiName: group.poiName,
                                    questCount: group.quests.count,
                                    completedCount: group.completedCount
                                )
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        viewModel.updateQuests()
                        if let location = locationService.currentLocation {
                            viewModel.sortByDistance(from: location)
                        }
                    }
                } else {
                    // Flat list
                    List(viewModel.filteredQuests) { quest in
                        QuestRowView(
                            quest: quest,
                            distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                            isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if quest.type == .trivia {
                                selectedQuizQuest = quest
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            questSwipeActions(for: quest)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        viewModel.updateQuests()
                        if let location = locationService.currentLocation {
                            viewModel.sortByDistance(from: location)
                        }
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
            }
            .onReceive(mapViewModel.$pois) { _ in
                syncPOIProgress()
            }
            .sheet(item: $selectedQuizQuest) { quest in
                QuizView(
                    poiId: quest.poiId,
                    poiName: quest.title,
                    category: "Sehenswürdigkeit",
                    xpPerQuestion: quest.calculatedXPReward / 5
                )
            }
        }
    }

    private func syncPOIProgress() {
        var progress: [UUID: POIProgress] = [:]
        for poi in mapViewModel.pois {
            if let userProgress = poi.userProgress {
                progress[poi.id] = userProgress
            }
        }
        viewModel.updatePOIProgress(progress)
    }

    @ViewBuilder
    private func questSwipeActions(for quest: Quest) -> some View {
        if viewModel.isInRange(of: quest, userLocation: locationService.currentLocation) {
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(poiName)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("\(completedCount)/\(questCount) abgeschlossen")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

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

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color.gray.opacity(0.15))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Quest Row

struct QuestRowView: View {
    let quest: Quest
    let distance: String?
    let isInRange: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Quest Icon
            ZStack {
                Circle()
                    .fill(difficultyColor.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: questIcon)
                    .foregroundColor(difficultyColor)
                    .font(.title2)

                // In Range Indicator
                if isInRange {
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

            if isInRange {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var questIcon: String {
        switch quest.type {
        case .visit: return "mappin.circle"
        case .photo: return "camera"
        case .ar: return "arkit"
        case .trivia: return "questionmark.circle"
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

// MARK: - Quest Type Extension

extension QuestType {
    var displayName: String {
        switch self {
        case .visit: return "Besuchen"
        case .photo: return "Foto"
        case .ar: return "AR"
        case .trivia: return "Quiz"
        }
    }
}

#Preview {
    QuestsView()
        .environmentObject(LocationService())
        .environmentObject(MapViewModel())
}
