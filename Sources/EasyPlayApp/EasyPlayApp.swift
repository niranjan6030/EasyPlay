import SwiftUI
import EasyPlayKit

@main
struct EasyPlayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("EasyPlay") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.refresh() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
