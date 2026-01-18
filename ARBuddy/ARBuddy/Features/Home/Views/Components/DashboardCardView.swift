//
//  DashboardCardView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI

struct DashboardCardView<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    DashboardCardView(title: "Test Card") {
        Text("Card Content")
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
    }
    .padding()
}
