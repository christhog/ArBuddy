//
//  HomeView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @StateObject private var viewModel = HomeViewModel()
    @State private var showSettings = false

    // Fallback user for when not logged in
    private var displayUser: User {
        if let appUser = supabaseService.currentUser {
            return User(
                id: appUser.id,
                username: appUser.username,
                email: appUser.email,
                xp: appUser.xp,
                level: appUser.level,
                completedQuests: []
            )
        }
        return User(
            username: "Abenteurer",
            email: "abenteurer@arbuddy.app",
            xp: 0,
            level: 1,
            completedQuests: []
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 1. Globe Hero Element (interaktiv: drehbar, zoombar)
                    GlobeView(
                        countryProgress: viewModel.countryProgress,
                        isLoading: viewModel.isLoadingCountries
                    )
                    .frame(height: 320)

                    // 2. Stats Grid (POIs, XP, Level)
                    StatsGridView(
                        user: displayUser,
                        poiStats: supabaseService.userStatistics
                    )

                    // 3. Quest-Type Progress (Visits, Photos, AR, Quiz)
                    if supabaseService.isAuthenticated {
                        POIProgressSectionView(stats: supabaseService.userStatistics)
                    }

                    // 4. Country Progress Grid
                    DashboardCardView(title: "Länder-Fortschritt") {
                        CountryProgressMapView(
                            countryProgress: viewModel.countryProgress,
                            isLoading: viewModel.isLoadingCountries
                        )
                    }

                    // 5. All Achievements
                    AchievementsSectionView(stats: supabaseService.userStatistics)
                }
                .padding()
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                // Refresh user profile and statistics on appear
                _ = try? await supabaseService.getUserProfile()
                await supabaseService.loadUserStatistics()

                // Load country progress from Supabase
                await viewModel.loadCountryProgress()
            }
            .refreshable {
                _ = try? await supabaseService.getUserProfile()
                await supabaseService.loadUserStatistics()

                // Refresh country progress from Supabase
                await viewModel.loadCountryProgress()
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(SupabaseService.shared)
}
