import Foundation
import Combine
import Supabase

// MARK: - Notifications
extension Notification.Name {
    static let questCompleted = Notification.Name("questCompleted")
}

// MARK: - App User Model (Supabase-compatible)
struct AppUser: Identifiable, Codable, Equatable {
    let id: UUID
    var email: String
    var username: String
    var xp: Int
    var level: Int
    var createdAt: Date
    var selectedBuddyId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, email, username, xp, level
        case createdAt = "created_at"
        case selectedBuddyId = "selected_buddy_id"
    }

    // Computed properties for XP progress
    var xpProgress: Double {
        let currentLevelXP = xpForCurrentLevel
        let nextLevelXP = xpForNextLevel
        let range = nextLevelXP - currentLevelXP
        if range <= 0 { return 1.0 }
        return Double(xp - currentLevelXP) / Double(range)
    }

    var xpToNextLevel: Int {
        return xpForNextLevel - xp
    }

    var xpForCurrentLevel: Int {
        // Level formula: level = floor(sqrt(xp / 100)) + 1
        // Inverse: xp = (level - 1)^2 * 100
        return (level - 1) * (level - 1) * 100
    }

    var xpForNextLevel: Int {
        return level * level * 100
    }
}

// MARK: - User POI Statistics
struct UserPOIStatistics: Codable {
    let totalPoisVisited: Int
    let fullyCompletedPois: Int
    let visitQuestsCompleted: Int
    let photoQuestsCompleted: Int
    let arQuestsCompleted: Int
    let quizQuestsCompleted: Int
    let totalPoiXp: Int

    enum CodingKeys: String, CodingKey {
        case totalPoisVisited = "total_pois_visited"
        case fullyCompletedPois = "fully_completed_pois"
        case visitQuestsCompleted = "visit_quests_completed"
        case photoQuestsCompleted = "photo_quests_completed"
        case arQuestsCompleted = "ar_quests_completed"
        case quizQuestsCompleted = "quiz_quests_completed"
        case totalPoiXp = "total_poi_xp"
    }

    init(
        totalPoisVisited: Int = 0,
        fullyCompletedPois: Int = 0,
        visitQuestsCompleted: Int = 0,
        photoQuestsCompleted: Int = 0,
        arQuestsCompleted: Int = 0,
        quizQuestsCompleted: Int = 0,
        totalPoiXp: Int = 0
    ) {
        self.totalPoisVisited = totalPoisVisited
        self.fullyCompletedPois = fullyCompletedPois
        self.visitQuestsCompleted = visitQuestsCompleted
        self.photoQuestsCompleted = photoQuestsCompleted
        self.arQuestsCompleted = arQuestsCompleted
        self.quizQuestsCompleted = quizQuestsCompleted
        self.totalPoiXp = totalPoiXp
    }
}

// MARK: - Completed Quest Entry (from user_poi_progress joined with pois)

struct CompletedQuestPOIInfo: Codable {
    let name: String
    let category: String
    let city: String?
    let description: String?
    let aiFacts: [String]?
    let quizDescription: String?
    let aiDescription: String?

    enum CodingKeys: String, CodingKey {
        case name, category, city, description
        case aiFacts = "ai_facts"
        case quizDescription = "quiz_description"
        case aiDescription = "ai_description"
    }

    /// Returns quiz description, falling back to ai_description for older quests
    var effectiveQuizDescription: String? {
        quizDescription ?? aiDescription
    }
}

struct CompletedQuestEntry: Identifiable, Codable {
    let id: UUID
    let userId: UUID
    let poiId: UUID
    let visitCompleted: Bool
    let photoCompleted: Bool
    let arCompleted: Bool
    let quizCompleted: Bool
    let quizScore: Int?
    let xpEarned: Int
    let updatedAt: Date?
    let pois: CompletedQuestPOIInfo

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case poiId = "poi_id"
        case visitCompleted = "visit_completed"
        case photoCompleted = "photo_completed"
        case arCompleted = "ar_completed"
        case quizCompleted = "quiz_completed"
        case quizScore = "quiz_score"
        case xpEarned = "xp_earned"
        case updatedAt = "updated_at"
        case pois
    }

    var completedTypes: [String] {
        var types: [String] = []
        if visitCompleted { types.append("Besuchen") }
        if photoCompleted { types.append("Foto") }
        if arCompleted { types.append("AR") }
        if quizCompleted { types.append("Quiz") }
        return types
    }

    var completedCount: Int {
        var count = 0
        if visitCompleted { count += 1 }
        if photoCompleted { count += 1 }
        if arCompleted { count += 1 }
        if quizCompleted { count += 1 }
        return count
    }
}

// MARK: - Supabase Service
@MainActor
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    // MARK: - Configuration
    private static let supabaseURL = "https://ibhaixdirrejsxalntvx.supabase.co"
    private static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImliaGFpeGRpcnJlanN4YWxudHZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg1NjU0NjksImV4cCI6MjA4NDE0MTQ2OX0.966UbEaN19b3leFVi0PR_H1j0F95yAOW8C-oEGHbbyw"

    let client: SupabaseClient

    // MARK: - Published State
    @Published var currentUser: AppUser?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var userStatistics: UserPOIStatistics = UserPOIStatistics()

    // MARK: - Buddy State
    @Published var availableBuddies: [Buddy] = []
    @Published var selectedBuddy: Buddy?

    // MARK: - Initialization
    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: Self.supabaseURL)!,
            supabaseKey: Self.supabaseAnonKey
        )

        // Listen for auth state changes
        Task {
            await setupAuthListener()
        }
    }

    private func setupAuthListener() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn:
                if let session = session {
                    isAuthenticated = true
                    await loadUserProfile(userId: session.user.id)
                    await loadUserStatistics()
                    await loadBuddyData()
                } else {
                    isAuthenticated = false
                    currentUser = nil
                    userStatistics = UserPOIStatistics()
                    availableBuddies = []
                    selectedBuddy = nil
                }
            case .signedOut:
                isAuthenticated = false
                currentUser = nil
                userStatistics = UserPOIStatistics()
                availableBuddies = []
                selectedBuddy = nil
            default:
                break
            }
        }
    }

    // MARK: - Authentication

    func signUp(email: String, password: String, username: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["username": .string(username)]
            )

            if let session = response.session {
                isAuthenticated = true
                await loadUserProfile(userId: session.user.id)
            }
        } catch {
            errorMessage = parseAuthError(error)
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let session = try await client.auth.signIn(
                email: email,
                password: password
            )

            isAuthenticated = true
            await loadUserProfile(userId: session.user.id)
            await loadUserStatistics()
        } catch {
            errorMessage = parseAuthError(error)
            throw error
        }
    }

    func signOut() async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await client.auth.signOut()
            isAuthenticated = false
            currentUser = nil
            userStatistics = UserPOIStatistics()
        } catch {
            errorMessage = "Abmeldung fehlgeschlagen"
            throw error
        }
    }

    func checkAuthStatus() async {
        do {
            let session = try await client.auth.session
            isAuthenticated = true
            await loadUserProfile(userId: session.user.id)
            await loadUserStatistics()
        } catch {
            isAuthenticated = false
            currentUser = nil
        }
    }

    private func parseAuthError(_ error: Error) -> String {
        let errorString = error.localizedDescription.lowercased()

        if errorString.contains("invalid login credentials") {
            return "Ungültige E-Mail oder Passwort"
        } else if errorString.contains("email already registered") || errorString.contains("user already registered") {
            return "Diese E-Mail ist bereits registriert"
        } else if errorString.contains("invalid email") {
            return "Ungültige E-Mail-Adresse"
        } else if errorString.contains("password") && errorString.contains("6") {
            return "Passwort muss mindestens 6 Zeichen haben"
        } else if errorString.contains("network") || errorString.contains("connection") {
            return "Keine Internetverbindung"
        }

        return "Ein Fehler ist aufgetreten. Bitte versuche es erneut."
    }

    // MARK: - User Profile

    private func loadUserProfile(userId: UUID) async {
        do {
            let user: AppUser = try await client
                .from("users")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            currentUser = user
        } catch {
            print("Failed to load user profile: \(error)")
            // User profile might not exist yet (trigger should create it)
            // Retry after a short delay
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await retryLoadUserProfile(userId: userId)
        }
    }

    private func retryLoadUserProfile(userId: UUID) async {
        do {
            let user: AppUser = try await client
                .from("users")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            currentUser = user
        } catch {
            print("Retry failed to load user profile: \(error)")
        }
    }

    func getUserProfile() async throws -> AppUser {
        guard let userId = try? await client.auth.session.user.id else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])
        }

        let user: AppUser = try await client
            .from("users")
            .select()
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value

        await MainActor.run {
            self.currentUser = user
        }

        return user
    }

    // MARK: - User Statistics

    func loadUserStatistics() async {
        guard let userId = currentUser?.id else { return }

        do {
            // Query the user_poi_statistics view
            let stats: [UserPOIStatistics] = try await client
                .from("user_poi_statistics")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            if let stat = stats.first {
                userStatistics = stat
            }
        } catch {
            print("Failed to load user statistics: \(error)")
            // Statistics might not exist yet if user hasn't completed any POIs
        }
    }

    // MARK: - XP & Quests

    func addXP(_ amount: Int) async throws {
        guard let userId = currentUser?.id else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])
        }

        // Update XP directly in the users table
        let newXP = (currentUser?.xp ?? 0) + amount
        let newLevel = Int(floor(sqrt(Double(newXP) / 100))) + 1

        try await client
            .from("users")
            .update(["xp": newXP, "level": newLevel])
            .eq("id", value: userId.uuidString)
            .execute()

        // Refresh user profile
        await loadUserProfile(userId: userId)
    }

    // MARK: - POI Progress

    /// Complete a quest for a POI
    func completePOIQuest(poiId: UUID, questType: String, xpEarned: Int, quizScore: Int? = nil) async throws {
        guard let userId = currentUser?.id else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])
        }

        // Call the database function to complete the quest
        try await client
            .rpc("complete_poi_quest", params: CompleteQuestRequest(
                userId: userId.uuidString,
                poiId: poiId.uuidString,
                questType: questType,
                xpEarned: xpEarned,
                quizScore: quizScore
            ))
            .execute()

        // Add XP to user
        try await addXP(xpEarned)

        // Reload statistics
        await loadUserStatistics()

        // Notify observers that a quest was completed
        NotificationCenter.default.post(name: .questCompleted, object: poiId)
    }

    // MARK: - Quiz Generation

    func generateQuiz(poiName: String, category: String) async throws -> Quiz {
        // Supabase SDK decodes directly to the specified type
        let quiz: Quiz = try await client.functions.invoke(
            "generate-quiz",
            options: FunctionInvokeOptions(
                body: QuizRequestByName(poiName: poiName, category: category)
            )
        )

        print("Quiz loaded with \(quiz.questions.count) questions, description: \(quiz.description ?? "nil")")
        return quiz
    }

    /// Generate quiz using POI ID (new approach)
    func generateQuiz(poiId: UUID) async throws -> Quiz {
        let quiz: Quiz = try await client.functions.invoke(
            "generate-quiz",
            options: FunctionInvokeOptions(
                body: QuizRequestById(poiId: poiId.uuidString)
            )
        )

        print("Quiz loaded with \(quiz.questions.count) questions for POI: \(poiId), description: \(quiz.description ?? "nil")")
        return quiz
    }

    // MARK: - POI Enrichment

    /// Enrich a POI with AI-generated content
    func enrichPOI(poiId: UUID, contentType: String, eventType: String? = nil) async throws -> [String: Any] {
        let response: EnrichPOIResponse = try await client.functions.invoke(
            "enrich-poi",
            options: FunctionInvokeOptions(
                body: EnrichPOIRequest(
                    poiId: poiId.uuidString,
                    contentType: contentType,
                    eventType: eventType
                )
            )
        )

        var result: [String: Any] = [:]
        if let questions = response.questions {
            result["questions"] = questions
        }
        if let cached = response.cached {
            result["cached"] = cached
        }

        return result
    }

    // MARK: - Country Statistics

    func fetchCountryStatistics() async throws -> [CountryStatistics] {
        let response: [CountryStatistics] = try await client
            .from("user_country_statistics")
            .select()
            .execute()
            .value
        return response
    }

    // MARK: - POI Fetching (via Edge Function)

    /// Result type for POI fetch that includes both POIs and quests
    struct POIFetchResult {
        let pois: [EdgePOI]
        let quests: [EdgePOIQuest]
    }

    func fetchPOIs(latitude: Double, longitude: Double, radius: Double = 5000, skipGeoapify: Bool = false) async throws -> [EdgePOI] {
        let result = try await fetchPOIsWithQuests(latitude: latitude, longitude: longitude, radius: radius, skipGeoapify: skipGeoapify)
        return result.pois
    }

    /// Fetches POIs along with their associated quests from Supabase
    func fetchPOIsWithQuests(latitude: Double, longitude: Double, radius: Double = 5000, skipGeoapify: Bool = false) async throws -> POIFetchResult {
        let response: POIResponse = try await client.functions.invoke(
            "fetch-pois",
            options: FunctionInvokeOptions(
                body: POIFetchRequestWithSkip(
                    latitude: latitude,
                    longitude: longitude,
                    radius: radius,
                    userId: currentUser?.id.uuidString,
                    skipGeoapify: skipGeoapify
                )
            )
        )

        print("[SupabaseService] Loaded \(response.pois.count) POIs with \(response.quests.count) quests (skipGeoapify requested: \(skipGeoapify))")
        if let debug = response.debug {
            print("[POI Debug] GeoapifyFetched: \(debug.geoapifyFetched ?? false), GeoapifyCount: \(debug.geoapifyCount ?? 0), ExistingDB: \(debug.existingInDB ?? 0), NewInserted: \(debug.newlyInserted ?? 0), Final: \(debug.finalCount ?? 0), Quests: \(debug.questCount ?? 0)")
        }
        return POIFetchResult(pois: response.pois, quests: response.quests)
    }

    // MARK: - POI Fetching (Database Only - No Geoapify)

    /// Fetches POIs directly from the database without calling Geoapify API.
    /// Use this for pre-fetching at app startup when you only need known POIs.
    func fetchPOIsFromDatabase(latitude: Double, longitude: Double, radius: Double = 5000) async throws -> [EdgePOI] {
        // Use the edge function with skipGeoapify flag
        return try await fetchPOIs(latitude: latitude, longitude: longitude, radius: radius, skipGeoapify: true)
    }

    // MARK: - POI Quest Fetching

    /// Fetches quests for specific POI IDs directly from Supabase
    func fetchPOIQuests(poiIds: [UUID]) async throws -> [POIQuest] {
        guard !poiIds.isEmpty else { return [] }

        struct DBPOIQuest: Codable {
            let id: UUID
            let poiId: UUID
            let questType: String
            let title: String
            let description: String?
            let xpReward: Int
            let difficulty: String

            enum CodingKeys: String, CodingKey {
                case id
                case poiId = "poi_id"
                case questType = "quest_type"
                case title
                case description
                case xpReward = "xp_reward"
                case difficulty
            }
        }

        let quests: [DBPOIQuest] = try await client
            .from("poi_quests")
            .select()
            .in("poi_id", values: poiIds.map { $0.uuidString })
            .execute()
            .value

        return quests.map { dbQuest in
            POIQuest(
                id: dbQuest.id,
                poiId: dbQuest.poiId,
                questType: QuestType(rawValue: dbQuest.questType) ?? .visit,
                title: dbQuest.title,
                description: dbQuest.description,
                xpReward: dbQuest.xpReward,
                difficulty: QuestDifficulty(rawValue: dbQuest.difficulty) ?? .easy
            )
        }
    }

    // MARK: - World Quest Fetching

    /// Fetches world quests near a location
    func fetchWorldQuests(latitude: Double, longitude: Double, radius: Double = 10000) async throws -> [WorldQuest] {
        let quests: [WorldQuest] = try await client
            .rpc("world_quests_within_radius", params: [
                "lat": latitude,
                "lon": longitude,
                "radius_meters": radius
            ])
            .execute()
            .value

        print("[SupabaseService] Loaded \(quests.count) world quests")
        return quests
    }

    /// Fetches all active world quests
    func fetchAllActiveWorldQuests() async throws -> [WorldQuest] {
        let quests: [WorldQuest] = try await client
            .from("world_quests")
            .select()
            .eq("is_active", value: true)
            .execute()
            .value

        print("[SupabaseService] Loaded \(quests.count) active world quests")
        return quests
    }

    /// Completes a world quest for the current user
    func completeWorldQuest(worldQuestId: UUID, xpEarned: Int) async throws {
        guard let userId = currentUser?.id else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])
        }

        try await client
            .rpc("complete_world_quest", params: CompleteWorldQuestRequest(
                userId: userId.uuidString,
                worldQuestId: worldQuestId.uuidString,
                xpEarned: xpEarned
            ))
            .execute()

        // Add XP to user
        try await addXP(xpEarned)

        print("[SupabaseService] Completed world quest: \(worldQuestId)")
    }

    // MARK: - Completed Quests

    /// Fetches all completed quest progress for the current user, joined with POI data
    func fetchCompletedQuests(userId: UUID) async throws -> [CompletedQuestEntry] {
        let entries: [CompletedQuestEntry] = try await client
            .from("user_poi_progress")
            .select("*, pois(name, category, city, description, ai_facts, quiz_description, ai_description)")
            .eq("user_id", value: userId.uuidString)
            .order("updated_at", ascending: false)
            .execute()
            .value

        return entries
    }

    /// Fetches a single completed quest entry by POI ID for the current user
    func fetchCompletedQuestEntry(poiId: UUID) async throws -> CompletedQuestEntry? {
        guard let userId = currentUser?.id else { return nil }

        let entries: [CompletedQuestEntry] = try await client
            .from("user_poi_progress")
            .select("*, pois(name, category, city, description, ai_facts, quiz_description, ai_description)")
            .eq("user_id", value: userId.uuidString)
            .eq("poi_id", value: poiId.uuidString)
            .execute()
            .value

        return entries.first
    }

    // MARK: - Buddies

    /// Fetches all available buddies from the database
    func fetchBuddies() async throws -> [Buddy] {
        let buddies: [Buddy] = try await client
            .from("buddies")
            .select()
            .order("sort_order")
            .execute()
            .value

        availableBuddies = buddies
        print("Loaded \(buddies.count) buddies")
        return buddies
    }

    /// Returns the currently selected buddy for the user
    func getSelectedBuddy() async throws -> Buddy? {
        // Ensure buddies are loaded
        if availableBuddies.isEmpty {
            _ = try await fetchBuddies()
        }

        // Get buddy ID from current user
        guard let buddyId = currentUser?.selectedBuddyId else {
            // Return default buddy if no selection
            let defaultBuddy = availableBuddies.first { $0.isDefault }
            selectedBuddy = defaultBuddy
            return defaultBuddy
        }

        let buddy = availableBuddies.first { $0.id == buddyId }
        selectedBuddy = buddy
        return buddy
    }

    /// Selects a buddy for the current user
    func selectBuddy(_ buddy: Buddy) async throws {
        guard let userId = currentUser?.id else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Nicht eingeloggt"])
        }

        try await client
            .from("users")
            .update(["selected_buddy_id": buddy.id.uuidString])
            .eq("id", value: userId.uuidString)
            .execute()

        // Update local state
        selectedBuddy = buddy

        // Update current user's selected buddy ID
        if var user = currentUser {
            user.selectedBuddyId = buddy.id
            currentUser = user
        }

        print("Selected buddy: \(buddy.name)")
    }

    /// Loads buddies and sets selected buddy on login
    func loadBuddyData() async {
        do {
            _ = try await fetchBuddies()
            _ = try await getSelectedBuddy()
        } catch {
            print("Failed to load buddy data: \(error)")
        }
    }
}
