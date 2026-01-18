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
    @State private var selectedCategory: POICategory?
    @State private var selectedFilter: POIProgressFilter = .all

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $position) {
                    UserAnnotation()

                    ForEach(viewModel.filteredPOIs(category: selectedCategory, progressFilter: selectedFilter)) { poi in
                        Annotation(poi.name, coordinate: poi.coordinate) {
                            POIMarkerView(
                                poi: poi,
                                isSelected: viewModel.selectedPOI?.id == poi.id,
                                questCount: viewModel.quests(for: poi).count
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
                        // Category Filter
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                CategoryChip(
                                    title: "Alle",
                                    icon: "mappin",
                                    isSelected: selectedCategory == nil
                                ) {
                                    selectedCategory = nil
                                }

                                ForEach(POICategory.allCases, id: \.self) { category in
                                    CategoryChip(
                                        title: category.displayName,
                                        icon: category.iconName,
                                        isSelected: selectedCategory == category
                                    ) {
                                        selectedCategory = category
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
                            questCount: viewModel.quests(for: poi).count
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
                                await viewModel.loadPOIs(near: location, radius: 5000)
                            }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
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
    let questCount: Int

    private var progressColor: Color {
        guard let progress = poi.userProgress else { return .blue }
        if progress.isFullyCompleted { return .green }
        if progress.completedCount > 0 { return .orange }
        return .blue
    }

    private var showCompletionBadge: Bool {
        poi.userProgress?.completedCount ?? 0 > 0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? progressColor : Color.white)
                .frame(width: 44, height: 44)
                .shadow(radius: 3)

            // Outer ring for progress
            if let progress = poi.userProgress, progress.completedCount > 0 {
                Circle()
                    .stroke(progressColor, lineWidth: 3)
                    .frame(width: 48, height: 48)
            }

            Image(systemName: poi.category.iconName)
                .foregroundColor(isSelected ? .white : progressColor)
                .font(.system(size: 18))

            // Completion badge
            if showCompletionBadge {
                Image(systemName: poi.userProgress?.isFullyCompleted == true ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                    .foregroundColor(progressColor)
                    .font(.caption)
                    .background(Circle().fill(.white).frame(width: 16, height: 16))
                    .offset(x: 16, y: -16)
            }

            // Quest Badge (only if no completion badge)
            if !showCompletionBadge && questCount > 0 {
                Text("\(questCount)")
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
    let questCount: Int
    let onDismiss: () -> Void

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

            // Progress Bar (if user has progress)
            if let progress = poi.userProgress, progress.completedCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fortschritt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(progress.completedCount)/4 Quests")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ProgressView(value: progress.progressPercentage)
                        .tint(progress.isFullyCompleted ? .green : .orange)

                    // Quest completion icons
                    HStack(spacing: 8) {
                        QuestCompletionIcon(type: .visit, isCompleted: progress.visitCompleted)
                        QuestCompletionIcon(type: .photo, isCompleted: progress.photoCompleted)
                        QuestCompletionIcon(type: .ar, isCompleted: progress.arCompleted)
                        QuestCompletionIcon(type: .trivia, isCompleted: progress.quizCompleted)
                    }
                }
            }

            HStack {
                Label(poi.category.displayName, systemImage: poi.category.iconName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if questCount > 0 {
                    Label("\(questCount) Quest\(questCount == 1 ? "" : "s")", systemImage: "list.bullet")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if questCount > 0 {
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
        case .trivia: return isCompleted ? "checkmark.circle.fill" : "questionmark.circle"
        }
    }
}

// MARK: - POI Quests View

struct POIQuestsView: View {
    let poi: POI
    @StateObject private var viewModel = QuestsViewModel()
    @EnvironmentObject var locationService: LocationService

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

                    if let progress = poi.userProgress {
                        ProgressView(value: progress.progressPercentage)
                            .tint(progress.isFullyCompleted ? .green : .orange)
                        Text("\(progress.completedCount)/4 Quests abgeschlossen")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Quests Section
            Section("Verfügbare Quests") {
                ForEach(QuestService.shared.quests(for: poi.id)) { quest in
                    QuestRowView(
                        quest: quest,
                        distance: viewModel.distance(to: quest, from: locationService.currentLocation),
                        isInRange: viewModel.isInRange(of: quest, userLocation: locationService.currentLocation)
                    )
                }
            }
        }
        .navigationTitle(poi.name)
        .navigationBarTitleDisplayMode(.inline)
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
