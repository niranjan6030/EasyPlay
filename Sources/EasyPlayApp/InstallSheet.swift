import SwiftUI
import UniformTypeIdentifiers
import EasyPlayKit

/// The guided install: pick an installer, confirm the preset, go.
///
/// The preset is chosen automatically when the filename is recognised, and shown
/// rather than hidden — a user who wants to know what is being applied to their
/// system can read it before pressing the button.
struct InstallSheet: View {
    var preselectedInstaller: URL?
    var preselectedRecipeID: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var installerURL: URL?
    @State private var selectedRecipeID: String?
    @State private var bottleName = ""
    @State private var showingFileImporter = false
    @State private var isDropTargeted = false

    private var recipe: Recipe? { model.recipe(id: selectedRecipeID) }

    /// Steam games have no installer to choose — the client is the installer.
    private var isSteamGame: Bool { recipe?.install.kind == .steam }

    private var steamExplanation: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Label("This game is sold through Steam", systemImage: "cart")
                .font(.callout.weight(.medium))
            Text("There's no installer to choose. EasyPlay downloads the game with Valve's own SteamCMD after you sign in once. Your password and Steam Guard code go into Valve's sign-in window, never into EasyPlay.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Steam account name", text: $model.steamUsername,
                          prompt: Text("Steam account name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { model.refreshSteamStatus() }
                Button("Sign in to Steam") { model.signInToSteam() }
                Button {
                    model.refreshSteamStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Check sign-in")
            }

            Group {
                switch model.steamSignedIn {
                case .some(true):
                    Label("Signed in — ready to install", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .some(false):
                    Label("Not signed in yet", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                case .none:
                    Label("Checking…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if recipe?.compatibility.rating != .runsGreat {
                Text("Free games must be in your Steam library first: open the game's store page and press Play Game or Add to Library once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshSteamStatus() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Install a game")
                .font(.title3.weight(.semibold))
                .padding(20)

            Divider()

            Form {
                if isSteamGame {
                    Section {
                        steamExplanation
                    } header: {
                        Text("How this one installs")
                    }
                } else {
                    Section {
                        installerRow
                    } header: {
                        Text("Installer")
                    }
                }

                Section {
                    Picker("Preset", selection: $selectedRecipeID) {
                        Text("None — plain Wine defaults").tag(String?.none)
                        ForEach(model.recipes.filter { $0.compatibility.rating.isPlayable }) { recipe in
                            Text(recipe.title).tag(String?.some(recipe.id))
                        }
                    }

                    if let recipe {
                        recipeSummary(recipe)
                    } else {
                        Text("Without a preset, EasyPlay creates a plain Windows environment and runs the installer in it. That works for simple programs; games usually need a preset.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Configuration")
                }

                Section {
                    TextField("Bottle name", text: $bottleName)
                        .textFieldStyle(.roundedBorder)
                    Text("Each game gets its own isolated Windows environment, so one broken game can't affect the others.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Where it goes")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let recipe, recipe.compatibility.rating == .untested {
                    Label("This preset hasn't been verified yet.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSteamGame ? "Install through Steam" : "Install") {
                    let name = bottleName.isEmpty ? defaultBottleName : bottleName
                    if isSteamGame, let recipe {
                        model.installFromSteam(recipe: recipe, bottleName: name)
                    } else if let installerURL {
                        model.install(installerAt: installerURL, recipe: recipe, bottleName: name)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSteamGame
                          ? (recipe == nil || model.steamSignedIn != true)
                          : installerURL == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            if let preselectedRecipeID {
                selectedRecipeID = preselectedRecipeID
                if bottleName.isEmpty { bottleName = defaultBottleName }
            }
            if let preselectedInstaller { adopt(preselectedInstaller) }
        }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.executable, .diskImage, .zip, .folder, .data]) { result in
            if case .success(let url) = result { adopt(url) }
        }
    }

    @ViewBuilder
    private var installerRow: some View {
        if let installerURL {
            HStack {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installerURL.lastPathComponent).lineLimit(1)
                    Text(installerURL.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Button("Change") { showingFileImporter = true }
            }
        } else {
            // A drop zone rather than only a button: dragging the download
            // straight in is how people actually have the file to hand.
            VStack(spacing: 10) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 26))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text("Drag a game here")
                    .font(.callout.weight(.medium))
                Text("An installer (.exe, .msi), a .zip, or a game folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose a file…") { showingFileImporter = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { InstallSheet.isAcceptable($0) }) else { return false }
                adopt(url)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        }
    }

    /// What can be dropped: an installer, an archive, or a folder holding the game.
    static func isAcceptable(_ url: URL) -> Bool { GameInstaller.canInstall(url) }

    private func recipeSummary(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CompatibilityBadge(rating: recipe.compatibility.rating)
                if let source = recipe.compatibility.source {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledContent("Windows", value: recipe.bottle.windowsVersion)
            LabeledContent("Graphics", value: recipe.graphics.backend.displayName)
            LabeledContent("Disk needed", value: "\(recipe.requires.diskGB) GB")

            ForEach(recipe.compatibility.notes.prefix(2), id: \.self) { note in
                Text("• \(note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var defaultBottleName: String {
        recipe?.title ?? installerURL?.deletingPathExtension().lastPathComponent ?? "New bottle"
    }

    private func adopt(_ url: URL) {
        installerURL = url
        if selectedRecipeID == nil,
           let matched = RecipeLibrary().matchRecipe(forInstallerNamed: url.lastPathComponent) {
            selectedRecipeID = matched.id
        }
        if bottleName.isEmpty { bottleName = defaultBottleName }
    }
}
