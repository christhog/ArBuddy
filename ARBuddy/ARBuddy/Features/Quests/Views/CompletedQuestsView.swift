//
//  CompletedQuestsView.swift
//  ARBuddy
//
//  Created by Chris Greve on 27.01.26.
//

import SwiftUI

struct CompletedQuestsView: View {
    @StateObject private var viewModel = CompletedQuestsViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.entries.isEmpty {
                ProgressView("Lade abgeschlossene Quests...")
            } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "Fehler",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "Keine abgeschlossenen Quests",
                    systemImage: "checkmark.seal",
                    description: Text("Schließe Quests ab, um sie hier zu sehen.")
                )
            } else {
                List(viewModel.entries) { entry in
                    NavigationLink(destination: CompletedQuestDetailView(entry: entry)) {
                        CompletedQuestRow(entry: entry)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await viewModel.fetchCompletedQuests()
                }
            }
        }
        .navigationTitle("Abgeschlossene Quests")
        .task {
            await viewModel.fetchCompletedQuests()
        }
    }
}

// MARK: - Completed Quest Row

struct CompletedQuestRow: View {
    let entry: CompletedQuestEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // POI Name + City
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.pois.name)
                        .font(.headline)

                    if let city = entry.pois.city {
                        Text(city)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // XP Badge
                Text("+\(entry.xpEarned) XP")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(8)
            }

            // Completed quest types
            HStack(spacing: 6) {
                ForEach(entry.completedTypes, id: \.self) { type in
                    Text(type)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                }

                Spacer()

                // Progress indicator
                Text("\(entry.completedCount)/4")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if entry.completedCount == 4 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            // Date
            if let date = entry.updatedAt {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        CompletedQuestsView()
    }
}
