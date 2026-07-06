import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ConnectionView()
        }
    }
}