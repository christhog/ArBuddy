//
//  ARBuddyApp.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI
import CoreLocation

@main
struct ARBuddyApp: App {
    @StateObject private var locationService = LocationService()
    @StateObject private var supabaseService = SupabaseService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register for memory warnings
        setupMemoryWarningHandler()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(locationService)
                .environmentObject(supabaseService)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    /// Sets up handler for memory warning notifications
    private func setupMemoryWarningHandler() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[ARBuddyApp] Memory warning received - unloading LLM model")
            Task {
                await LlamaService.shared.handleMemoryWarning()
            }
        }
    }

    /// Handles scene phase changes (background/foreground)
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Unload LLM model when going to background to save memory
            print("[ARBuddyApp] App entering background - unloading LLM model")
            Task {
                await LlamaService.shared.unloadModel()
            }
        case .active:
            // Model will be reloaded on demand when user opens chat
            print("[ARBuddyApp] App became active")
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Root View (Auth Gate)
struct RootView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @EnvironmentObject var locationService: LocationService
    @State private var isCheckingAuth = true
    @State private var hasPrefetchedPOIs = false

    var body: some View {
        Group {
            if isCheckingAuth {
                // Splash / Loading Screen
                SplashView()
            } else if supabaseService.isAuthenticated {
                // Main App
                MainTabView()
            } else {
                // Auth Flow
                AuthView()
            }
        }
        .task {
            await supabaseService.checkAuthStatus()
            isCheckingAuth = false

            // Try to pre-fetch POIs after auth check if location is already available
            tryPrefetchPOIs()
        }
        .onAppear {
            // Request location permission early for POI pre-fetching
            locationService.requestPermission()
        }
        .onChange(of: locationService.currentLocation) { _, _ in
            // Pre-fetch POIs when location becomes available
            tryPrefetchPOIs()
        }
        .onChange(of: supabaseService.currentUser) { _, _ in
            // Pre-fetch POIs when user profile is loaded (ensures userId is available)
            tryPrefetchPOIs()
        }
    }

    /// Tries to pre-fetch POIs if all conditions are met
    private func tryPrefetchPOIs() {
        guard let location = locationService.currentLocation,
              !hasPrefetchedPOIs,
              supabaseService.isAuthenticated,
              supabaseService.currentUser != nil else {
            return
        }

        hasPrefetchedPOIs = true
        Task {
            await prefetchPOIs(near: location)
        }
    }

    /// Pre-fetches POIs from the database (without Geoapify) at app startup
    private func prefetchPOIs(near location: CLLocation) async {
        print("[RootView] Pre-fetching POIs near (\(location.coordinate.latitude), \(location.coordinate.longitude))")
        print("[RootView] Current user: \(supabaseService.currentUser?.username ?? "nil")")

        do {
            // Fetch POIs directly from database (no Geoapify call)
            // User progress will be included because currentUser is set
            let pois = try await POIService.shared.fetchPOIsFromDatabase(
                near: location.coordinate,
                radius: 5000
            )

            print("[RootView] Pre-fetched \(pois.count) POIs from database")

            // Log progress info
            let poisWithProgress = pois.filter { $0.userProgress != nil }
            print("[RootView] POIs with user progress: \(poisWithProgress.count)")

            // Generate quests for these POIs
            await MainActor.run {
                _ = QuestService.shared.generateQuests(for: pois)
            }

            print("[RootView] Generated quests for pre-fetched POIs")
        } catch {
            print("[RootView] Pre-fetch failed: \(error.localizedDescription)")
            // Silently fail - POIs will be loaded when map opens
        }
    }
}

// MARK: - Splash View
struct SplashView: View {
    var body: some View {
        ZStack {
            Image("SplashImage")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "map.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.white)

                Text("ARBuddy")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            }
        }
    }
}
