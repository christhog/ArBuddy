//
//  AchievementsSectionView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct AchievementsSectionView: View {
    let stats: UserPOIStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erfolge")
                .font(.headline)

            HStack(spacing: 12) {
                AchievementBadge(
                    icon: "figure.walk",
                    title: "Entdecker",
                    isUnlocked: stats.totalPoisVisited >= 1
                )
                AchievementBadge(
                    icon: "camera.fill",
                    title: "Fotograf",
                    isUnlocked: stats.photoQuestsCompleted >= 5
                )
                AchievementBadge(
                    icon: "star.fill",
                    title: "Sammler",
                    isUnlocked: stats.fullyCompletedPois >= 3
                )
                AchievementBadge(
                    icon: "trophy.fill",
                    title: "Champion",
                    isUnlocked: stats.fullyCompletedPois >= 10
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AchievementBadge: View {
    let icon: String
    let title: String
    let isUnlocked: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.1))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .foregroundColor(isUnlocked ? .yellow : .gray.opacity(0.5))
            }

            Text(title)
                .font(.caption2)
                .foregroundColor(isUnlocked ? .primary : .secondary)
        }
    }
}

#Preview {
    AchievementsSectionView(stats: UserPOIStatistics())
}
