//
//  MainTabView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var mapViewModel = MapViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            ARBuddyView()
                .tabItem {
                    Label("AR", systemImage: "arkit")
                }
                .tag(1)

            MapTabView()
                .tabItem {
                    Label("Karte", systemImage: "map")
                }
                .tag(2)

            QuestsView()
                .tabItem {
                    Label("Quests", systemImage: "list.bullet.clipboard")
                }
                .tag(3)
        }
        .environmentObject(mapViewModel)
    }
}

#Preview {
    MainTabView()
        .environmentObject(LocationService())
        .environmentObject(SupabaseService.shared)
}
