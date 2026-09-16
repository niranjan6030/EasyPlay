import SwiftUI
import UniformTypeIdentifiers
import EasyPlayKit

/// The screen users actually live in: installed games, and a Play button.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showingInstaller = false
    @State private var droppedInstaller: URL?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 18)]

    var body: some View {
        Group {
            if model.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.games.sorted { $0.title < $1.title }) { game in
                            GameCard(game: game)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button {
                showingInstaller = true
            } label: {
                Label("Install a game", systemImage: "plus")
            }
            .disabled(!model.isReady)
        }
        // Dropping an installer straight onto the window is the shortest path
        // from "I have a setup file" to "it's installed".
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { InstallSheet.isAcceptable($0) }) else { return false }
            droppedInstaller = url
            showingInstaller = true
            return true
        }
        .sheet(isPresented: $showingInstaller) {
            InstallSheet(preselectedInstaller: droppedInstaller,
                         preselectedRecipeID: model.pendingInstallPresetID)
                .onDisappear {
                    droppedInstaller = nil
                    model.pendingInstallPresetID = nil
                }
        }
        // Arriving here from an answer in Ask opens the install sheet with that
        // game's preset already chosen.
        .onChange(of: model.pendingInstallPresetID) {
            if model.pendingInstallPresetID != nil { showingInstaller = true }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            Text("No games yet")
                .font(.title3.weight(.semibold))

            Text(model.isReady
                 ? "Drag a Windows installer onto this window, or press Install a game."
                 : "Finish setup first — EasyPlay needs the Wine engine before it can install anything.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                if model.isReady {
                    Button("Install a game") { showingInstaller = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Go to setup") { model.screen = .setup }
                        .buttonStyle(.borderedProminent)
                }
                Button("How to use EasyPlay") { model.screen = .guide }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GameCard: View {
    let game: InstalledGame
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(height: 118)
            .overlay(alignment: .topTrailing) {
                CompatibilityBadge(rating: game.currentRating(from: model.recipe(id: game.recipeID)), compact: true)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.play(game)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isReady)
                .padding(.top, 2)
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(hovering ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show bottle in Finder") {
                if let bottle = model.bottle(id: game.bottleID) {
                    NSWorkspace.shared.activateFileViewerSelecting([bottle.url])
                }
            }
            Divider()
            Button("Remove from library", role: .destructive) {
                model.removeGame(game)
            }
        }
    }

    private var subtitle: String {
        if let played = game.lastPlayedAt {
            return "Last played \(played.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Never played"
    }
}
