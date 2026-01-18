import Foundation
import Combine
import Supabase

// MARK: - Notifications
extension Notification.Name {
    static let questCompleted = Notification.Name("questCompleted")
}

// MARK: - App User Model (Supabase-compatible)
struct AppUser: Identifiable, Codable {
    let id: UUID
    var email: String
    var username: String
    var xp: Int
    var level: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, username, xp, level
        case createdAt = "created_at"
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
                } else {
                    isAuthenticated = false
                    currentUser = nil
                    userStatistics = UserPOIStatistics()
                }
            case .signedOut:
                isAuthenticated = false
                currentUser = nil
                userStatistics = UserPOIStatistics()
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

        print("Quiz loaded with \(quiz.questions.count) questions")
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

        print("Quiz loaded with \(quiz.questions.count) questions for POI: \(poiId)")
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

    func fetchPOIs(latitude: Double, longitude: Double, radius: Double = 5000) async throws -> [EdgePOI] {
        let response: POIResponse = try await client.functions.invoke(
            "fetch-pois",
            options: FunctionInvokeOptions(
                body: POIFetchRequest(
                    latitude: latitude,
                    longitude: longitude,
                    radius: radius,
                    userId: currentUser?.id.uuidString
                )
            )
        )

        print("Loaded \(response.pois.count) POIs from Edge Function")
        if let debug = response.debug {
            print("[POI Debug] Geoapify: \(debug.geoapifyCount ?? -1), ExistingDB: \(debug.existingInDB ?? -1), NewInserted: \(debug.newlyInserted ?? -1), Final: \(debug.finalCount ?? -1)")
        }
        return response.pois
    }
}
