//
//  User.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation

struct User: Identifiable, Codable {
    let id: UUID
    var username: String
    var email: String
    var xp: Int
    var level: Int
    var completedQuests: [UUID]
    var createdAt: Date

    // CodingKeys for Supabase snake_case compatibility
    enum CodingKeys: String, CodingKey {
        case id, username, email, xp, level
        case completedQuests = "completed_quests"
        case createdAt = "created_at"
    }

    init(
        id: UUID = UUID(),
        username: String,
        email: String,
        xp: Int = 0,
        level: Int = 1,
        completedQuests: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.xp = xp
        self.level = level
        self.completedQuests = completedQuests
        self.createdAt = createdAt
    }

    var xpForCurrentLevel: Int {
        return xpRequired(for: level)
    }

    var xpForNextLevel: Int {
        return xpRequired(for: level + 1)
    }

    var xpProgress: Double {
        let xpInCurrentLevel = xp - xpForCurrentLevel
        let xpNeeded = xpForNextLevel - xpForCurrentLevel
        guard xpNeeded > 0 else { return 1.0 }
        return min(1.0, max(0.0, Double(xpInCurrentLevel) / Double(xpNeeded)))
    }

    var xpToNextLevel: Int {
        return max(0, xpForNextLevel - xp)
    }

    private func xpRequired(for level: Int) -> Int {
        guard level > 1 else { return 0 }
        return (level - 1) * 100
    }
}
