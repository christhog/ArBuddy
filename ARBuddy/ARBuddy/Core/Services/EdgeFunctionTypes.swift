import Foundation

// MARK: - Request/Response Types for Edge Functions
// These types are defined in a separate file with explicit nonisolated Codable conformance
// to avoid MainActor isolation issues when used with Supabase SDK methods that require Sendable parameters.
// The project uses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so we must be explicit.

// MARK: - AnyCodable Helper

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    nonisolated init(_ value: Any) {
        self.value = value
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode AnyCodable"))
        }
    }
}

// MARK: - Complete Quest Request

struct CompleteQuestRequest: Sendable {
    let userId: String
    let poiId: String
    let questType: String
    let xpEarned: Int
    let quizScore: Int?

    nonisolated init(userId: String, poiId: String, questType: String, xpEarned: Int, quizScore: Int?) {
        self.userId = userId
        self.poiId = poiId
        self.questType = questType
        self.xpEarned = xpEarned
        self.quizScore = quizScore
    }
}

extension CompleteQuestRequest: Encodable {
    enum CodingKeys: String, CodingKey {
        case userId = "p_user_id"
        case poiId = "p_poi_id"
        case questType = "p_quest_type"
        case xpEarned = "p_xp_earned"
        case quizScore = "p_quiz_score"
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(poiId, forKey: .poiId)
        try container.encode(questType, forKey: .questType)
        try container.encode(xpEarned, forKey: .xpEarned)
        try container.encodeIfPresent(quizScore, forKey: .quizScore)
    }
}

// MARK: - Quiz Requests

struct QuizRequestByName: Sendable {
    let poiName: String
    let category: String

    nonisolated init(poiName: String, category: String) {
        self.poiName = poiName
        self.category = category
    }
}

extension QuizRequestByName: Encodable {
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(poiName, forKey: .poiName)
        try container.encode(category, forKey: .category)
    }

    enum CodingKeys: String, CodingKey {
        case poiName, category
    }
}

struct QuizRequestById: Sendable {
    let poiId: String

    nonisolated init(poiId: String) {
        self.poiId = poiId
    }
}

extension QuizRequestById: Encodable {
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(poiId, forKey: .poiId)
    }

    enum CodingKeys: String, CodingKey {
        case poiId
    }
}

// MARK: - POI Fetch Request

struct POIFetchRequest: Sendable {
    let latitude: Double
    let longitude: Double
    let radius: Double
    let userId: String?

    nonisolated init(latitude: Double, longitude: Double, radius: Double, userId: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.userId = userId
    }
}

extension POIFetchRequest: Encodable {
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(radius, forKey: .radius)
        try container.encodeIfPresent(userId, forKey: .userId)
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, radius, userId
    }
}

// MARK: - Enrich POI Types

struct EnrichPOIRequest: Sendable {
    let poiId: String
    let contentType: String
    let eventType: String?

    nonisolated init(poiId: String, contentType: String, eventType: String?) {
        self.poiId = poiId
        self.contentType = contentType
        self.eventType = eventType
    }
}

extension EnrichPOIRequest: Encodable {
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(poiId, forKey: .poiId)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(eventType, forKey: .eventType)
    }

    enum CodingKeys: String, CodingKey {
        case poiId, contentType, eventType
    }
}

struct EnrichPOIResponse: Sendable {
    let questions: [QuizQuestion]?
    let event: [String: AnyCodable]?
    let cached: Bool?
}

extension EnrichPOIResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questions = try container.decodeIfPresent([QuizQuestion].self, forKey: .questions)
        event = try container.decodeIfPresent([String: AnyCodable].self, forKey: .event)
        cached = try container.decodeIfPresent(Bool.self, forKey: .cached)
    }

    enum CodingKeys: String, CodingKey {
        case questions, event, cached
    }
}

// MARK: - POI Response Types

struct POIDebugInfo: Sendable, Decodable {
    let geoapifyCount: Int?
    let existingInDB: Int?
    let newlyInserted: Int?
    let finalCount: Int?
    let geoapifyFetched: Bool?
}

struct POIResponse: Sendable {
    let pois: [EdgePOI]
    let debug: POIDebugInfo?
}

extension POIResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pois = try container.decode([EdgePOI].self, forKey: .pois)
        debug = try container.decodeIfPresent(POIDebugInfo.self, forKey: .debug)
    }

    enum CodingKeys: String, CodingKey {
        case pois
        case debug = "_debug"
    }
}

struct EdgePOIProgress: Sendable {
    let visitCompleted: Bool
    let photoCompleted: Bool
    let arCompleted: Bool
    let quizCompleted: Bool
    let quizScore: Int?
}

extension EdgePOIProgress: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visitCompleted = try container.decode(Bool.self, forKey: .visitCompleted)
        photoCompleted = try container.decode(Bool.self, forKey: .photoCompleted)
        arCompleted = try container.decode(Bool.self, forKey: .arCompleted)
        quizCompleted = try container.decode(Bool.self, forKey: .quizCompleted)
        quizScore = try container.decodeIfPresent(Int.self, forKey: .quizScore)
    }

    enum CodingKeys: String, CodingKey {
        case visitCompleted, photoCompleted, arCompleted, quizCompleted, quizScore
    }
}

struct EdgePOI: Sendable {
    let id: String
    let name: String
    let description: String
    let category: String
    let latitude: Double
    let longitude: Double
    let geoapifyCategories: [String]?
    let street: String?
    let city: String?
    let hasQuiz: Bool?
    let aiFacts: [String]?
    let userProgress: EdgePOIProgress?
}

extension EdgePOI: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        geoapifyCategories = try container.decodeIfPresent([String].self, forKey: .geoapifyCategories)
        street = try container.decodeIfPresent(String.self, forKey: .street)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        hasQuiz = try container.decodeIfPresent(Bool.self, forKey: .hasQuiz)
        aiFacts = try container.decodeIfPresent([String].self, forKey: .aiFacts)
        userProgress = try container.decodeIfPresent(EdgePOIProgress.self, forKey: .userProgress)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, latitude, longitude
        case geoapifyCategories, street, city, hasQuiz, aiFacts, userProgress
    }
}
