import SwiftUI
import EasyPlayKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.screen) {
                Section("Start here") {
                    Label("How to use EasyPlay", systemImage: "book")
                        .tag(AppModel.Screen.guide)
                }
                Section("Games") {
                    Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
                        .tag(AppModel.Screen.ask)
                    Label("Library", systemImage: "gamecontroller")
                        .tag(AppModel.Screen.library)
                }
                Section("Behind the scenes") {
                    Label("Bottles", systemImage: "cube.box")
                        .tag(AppModel.Screen.bottles)
                    Label("Setup", systemImage: setupIcon)
                        .tag(AppModel.Screen.setup)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch model.screen {
                case .guide: GuideView()
                case .ask: AskView()
                case .library: LibraryView()
                case .bottles: BottlesView()
                case .setup: SetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if let activity = model.activity {
                ActivityOverlay(activity: activity)
            }
        }
        .sheet(isPresented: .init(get: { !model.diagnoses.isEmpty },
                                  set: { if !$0 { model.dismissDiagnoses() } })) {
            // The game has to be passed through: the fix buttons act on it, and
            // without it they silently never render.
            DiagnosisSheet(diagnoses: model.diagnoses, game: model.diagnosedGame)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    /// The sidebar icon doubles as the setup warning light, so a blocked
    /// environment is visible from anywhere in the app.
    private var setupIcon: String {
        guard let environment = model.environment else { return "gearshape" }
        if !environment.blockers.isEmpty { return "exclamationmark.triangle.fill" }
        if !environment.warnings.isEmpty { return "exclamationmark.circle" }
        return "checkmark.seal"
    }
}

/// Blocks interaction while a long Wine operation runs, and shows what it is
/// doing. Wine's own output is unreadable, so only EasyPlay's own progress
/// messages reach here.
struct ActivityOverlay: View {
    let activity: AppModel.Activity

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(activity.title).font(.title3.weight(.semibold))

                if let latest = activity.messages.last {
                    Text(latest)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .transition(.opacity)
                }

                if activity.messages.count > 1 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(activity.messages.dropLast().suffix(6).enumerated()), id: \.offset) { _, message in
                                Text(message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: 420, maxHeight: 100)
                }
            }
            .padding(32)
        }
        .animation(.default, value: activity.messages.count)
    }
}
