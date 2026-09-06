import SwiftUI
import EasyPlayKit

/// The "behind the scenes" screen.
///
/// Most users never need to open this. It exists because hiding complexity is
/// not the same as pretending it isn't there — when something goes wrong, being
/// able to see and delete the actual Windows environment is the fastest fix.
struct BottlesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewBottle = false
    @State private var pendingDeletion: Bottle?

    var body: some View {
        Group {
            if model.bottles.isEmpty {
                ContentUnavailableView {
                    Label("No bottles", systemImage: "cube.box")
                } description: {
                    Text("A bottle is an isolated Windows environment. EasyPlay creates one for each game you install.")
                }
            } else {
                List {
                    ForEach(model.bottles) { bottle in
                        BottleRow(bottle: bottle, onDelete: { pendingDeletion = bottle })
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Bottles")
        .toolbar {
            Button {
                showingNewBottle = true
            } label: {
                Label("New bottle", systemImage: "plus")
            }
            .disabled(!model.isReady)
        }
        .sheet(isPresented: $showingNewBottle) { NewBottleSheet() }
        .alert("Delete this bottle?", isPresented: .init(get: { pendingDeletion != nil },
                                                         set: { if !$0 { pendingDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { model.deleteBottle(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This permanently removes \"\(pendingDeletion?.name ?? "")\" and every game installed inside it.")
        }
    }
}

private struct BottleRow: View {
    let bottle: Bottle
    let onDelete: () -> Void

    @Environment(AppModel.self) private var model
    @State private var size: String = "—"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.box.fill")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name).font(.headline)
                Text("\(bottle.windowsVersion) · \(bottle.graphicsBackend.displayName) · \(size)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let recipeID = bottle.recipeID {
                    Text("Preset: \(recipeID)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button("Check") { model.verifyBottle(bottle) }
                .help("Runs a small Windows program to confirm this bottle works")
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([bottle.url])
                }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .task {
            // Measuring a 50 GB directory takes a moment, so it happens off the
            // main thread after the row is already on screen.
            let bottle = bottle
            let measured = await Task.detached { bottle.sizeOnDisk() }.value
            if let measured {
                size = ByteCountFormatter.string(fromByteCount: measured, countStyle: .file)
            }
        }
    }
}

private struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var recipeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New bottle")
                .font(.title3.weight(.semibold))
                .padding(20)
            Divider()

            Form {
                TextField("Name", text: $name)
                Picker("Preset", selection: $recipeID) {
                    Text("None").tag(String?.none)
                    ForEach(model.recipes.filter { $0.compatibility.rating.isPlayable }) { recipe in
                        Text(recipe.title).tag(String?.some(recipe.id))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.createBottle(named: name, recipe: model.recipe(id: recipeID))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 260)
    }
}
