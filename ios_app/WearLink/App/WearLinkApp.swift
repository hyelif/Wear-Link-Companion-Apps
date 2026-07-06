import SwiftUI

@main
struct WearLinkApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task {
                    await container.start()
                }
        }
    }
}