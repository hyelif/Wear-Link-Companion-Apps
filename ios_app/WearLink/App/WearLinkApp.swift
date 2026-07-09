import SwiftUI

@main
struct WearLinkApp: App {
    private let container = AppContainer()

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