import SwiftUI

/// Top-level tabs: live net tracking (needs a device) and field setup + scoring (runs anywhere).
struct RootView: View {
    @StateObject private var app = AppState()

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Nets", systemImage: "video.fill") }
            ScoringDemoView()
                .tabItem { Label("Field", systemImage: "figure.cricket") }
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.xyaxis.line") }
        }
        .tint(.green)
        .environmentObject(app)
    }
}

@main
struct CricketNetsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
