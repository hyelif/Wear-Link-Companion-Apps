import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        TabView {
            NavigationStack {
                ConnectionView()
            }
            .tabItem {
                Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
            }

            NavigationStack {
                HealthView()
            }
            .tabItem {
                Label("Health", systemImage: "heart")
            }

            NavigationStack {
                CallView()
            }
            .tabItem {
                Label("Calls", systemImage: "phone")
            }

            NavigationStack {
                NotificationView()
            }
            .tabItem {
                Label("Notifications", systemImage: "bell")
            }

            NavigationStack {
                MusicView()
            }
            .tabItem {
                Label("Music", systemImage: "music.note")
            }
        }
    }
}
