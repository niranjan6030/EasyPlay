import SwiftUI
import EasyPlayKit

/// The one-time setup screen.
///
/// Every command it would run is shown before it runs, and can be copied and run
/// by hand instead. Installing a two-gigabyte compatibility layer on someone's
/// Mac should never be a black box.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let environment = model.environment {
                    ForEach(environment.checks) { check in
                        CheckRow(check: check)
                        if check.id == "classic-wine", check.status != .ok {
                            Button {
                                model.installClassicWine()
                            } label: {
                                Label("Install Classic Wine", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.leading, 34)
                        }
                    }
                    engineNote(environment)
                } else {
                    ProgressView("Checking this Mac…").padding(.vertical, 40)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("Setup")
        .toolbar {
            Button {
                model.refresh()
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What EasyPlay needs")
                .font(.title2.weight(.semibold))
            Text("EasyPlay doesn't run Windows games itself. It sets up and drives Wine, the open-source compatibility layer, so you don't have to.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func engineNote(_ environment: EnvironmentReport) -> some View {
        if environment.preferredBackend == nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install the compatibility engine")
                        .font(.headline)
                    Text("This downloads Apple's Game Porting Toolkit through Homebrew — around 2 GB. It's the same command you'd run in Terminal, and you can uninstall it the same way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        model.installMissingDependency(BrewClient.gamePortingToolkit)
                    } label: {
                        Label("Install engine", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(environment.homebrewVersion == nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }
}

private struct CheckRow: View {
    let check: EnvironmentCheck
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(colour)
                .font(.title3)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.headline)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let remedy = check.remedy {
                    Text(remedy)
                        .font(.callout)
                        .foregroundStyle(colour)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let command = check.remedyCommand {
                    HStack(alignment: .top, spacing: 8) {
                        Text(command)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    private var colour: Color {
        switch check.status {
        case .ok: return .green
        case .warning: return .orange
        case .blocked: return .red
        }
    }
}
