//
//  ProfileHeaderView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct ProfileHeaderView: View {
    let user: User

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Text(String(user.username.prefix(1)).uppercased())
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }

            VStack(spacing: 4) {
                Text(user.username)
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Level \(user.level)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("\(user.xp) XP")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("\(user.xpForNextLevel) XP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ProgressView(value: user.xpProgress)
                    .tint(.blue)

                Text("Noch \(user.xpToNextLevel) XP bis Level \(user.level + 1)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
}

#Preview {
    ProfileHeaderView(user: User(
        username: "TestUser",
        email: "test@example.com",
        xp: 150,
        level: 2
    ))
}
