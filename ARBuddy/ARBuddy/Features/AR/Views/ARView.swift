//
//  ARView.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import SwiftUI
import RealityKit

struct ARBuddyView: View {
    @EnvironmentObject var locationService: LocationService

    var body: some View {
        ZStack {
            RealityView { content in
                let model = Entity()
                let mesh = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
                let material = SimpleMaterial(color: .systemBlue, roughness: 0.15, isMetallic: true)
                model.components.set(ModelComponent(mesh: mesh, materials: [material]))
                model.position = [0, 0.05, 0]

                let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
                anchor.addChild(model)
                content.add(anchor)
                content.camera = .spatialTracking
            }
            .edgesIgnoringSafeArea(.all)

            VStack {
                Spacer()

                VStack(spacing: 8) {
                    Text("AR Buddy")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Richte die Kamera auf eine flache Oberfläche")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding(.bottom, 100)
            }
        }
    }
}

#Preview {
    ARBuddyView()
        .environmentObject(LocationService())
}
