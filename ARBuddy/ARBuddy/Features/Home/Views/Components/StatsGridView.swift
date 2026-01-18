//
//  StatsGridView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct StatsGridView: View {
    let user: User
    let poiStats: UserPOIStatistics

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            StatCard(
                title: "POIs",
                value: "\(poiStats.totalPoisVisited)",
                icon: "mappin.circle.fill",
                color: .blue
            )
            StatCard(
                title: "XP",
                value: "\(user.xp)",
                icon: "star.fill",
                color: .orange
            )
            StatCard(
                title: "Level",
                value: "\(user.level)",
                icon: "arrow.up.circle.fill",
                color: .purple
            )
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    StatsGridView(
        user: User(username: "Test", email: "test@example.com", xp: 250, level: 3),
        poiStats: UserPOIStatistics()
    )
}
