import SwiftUI
import EasyPlayKit

/// The instructions, inside the app rather than in a README nobody opens.
///
/// It doubles as an honest scope statement: the last section says plainly what
/// EasyPlay cannot do. A tool that runs other people's software has limits, and
/// a user who hits one without warning assumes the app is broken.
struct GuideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, step: step)
                }
                limits
                footer
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle("How to use EasyPlay")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to use EasyPlay")
                .font(.largeTitle.weight(.semibold))
            Text("EasyPlay runs Windows games on your Mac by driving Wine, the open-source compatibility layer, so you don't have to set it up yourself. Five steps, start to finish.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct Step {
        let title: String
        let body: String
        let icon: String
        var action: (label: String, screen: AppModel.Screen)?
    }

    private var steps: [Step] {
        [
            Step(
                title: "Check your Mac is ready",
                body: "Open Setup. EasyPlay checks for Rosetta, Homebrew and the Wine engine, and offers to install anything missing. Every check shows the exact command being run, so nothing happens behind your back. This is a one-time step — about a 2 GB download.",
                icon: "checkmark.seal",
                action: ("Open Setup", .setup)
            ),
            Step(
                title: "Ask whether your game will run",
                body: "Before you spend money, ask. EasyPlay answers from a catalogue it ships with and tells you where each answer came from. It will say a game is impossible when it uses kernel anti-cheat, tell you when there's a native Mac version you should buy instead, or admit it doesn't know — it never guesses.",
                icon: "bubble.left.and.text.bubble.right",
                action: ("Open Ask", .ask)
            ),
            Step(
                title: "Get the game yourself",
                body: "EasyPlay does not supply games. Buy and download the game from wherever you normally would — Steam, GOG, Epic, or the publisher — and keep the installer somewhere you can find it. The answers in Ask link straight to the official store page.",
                icon: "bag"
            ),
            Step(
                title: "Install it",
                body: "Go to Library and press Install a game, or just drag the installer onto the window. EasyPlay recognises the game from the filename where it can, creates an isolated Windows environment for it, applies the right settings, and runs the installer. For games sold through Steam there's no file to choose: EasyPlay installs Steam, opens it for you to sign in, and waits for the download.",
                icon: "square.and.arrow.down",
                action: ("Open Library", .library)
            ),
            Step(
                title: "Press Play",
                body: "Your game appears in Library with a Play button and a badge saying how well it's expected to run. All the Wine configuration was applied at install time, so there is nothing else to set up.",
                icon: "play.circle",
                action: ("Open Library", .library)
            ),
            Step(
                title: "If something goes wrong",
                body: "EasyPlay reads Wine's output and tells you what broke in plain English — a missing Windows component, the wrong graphics setting — and offers a button that fixes it where a fix exists. The raw log is always one click away if you want it.",
                icon: "exclamationmark.triangle"
            ),
        ]
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What EasyPlay can't do", systemImage: "hand.raised")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                limit("Games with kernel-level anti-cheat",
                      "VALORANT, Fortnite, Apex Legends, Destiny 2 and similar titles load a Windows kernel driver. Wine provides Windows' user space, not its kernel, so these can never work — on EasyPlay, CrossOver, or anything else. Trying to bypass it risks your account, so EasyPlay refuses by name.")
                limit("Sign in to Steam for you",
                      "For games sold through Steam, EasyPlay installs the Steam client into the bottle and opens it — but you sign in yourself, in Steam's own window. EasyPlay never sees your password or your two-factor code. It waits and picks up again once your download finishes.")
                limit("Supply games",
                      "EasyPlay only installs games you already own. It points you at official stores and nowhere else.")
                limit("Guarantee an untested game works",
                      "A rating of Untested means exactly that. EasyPlay will tell you nothing is obviously blocking a game, and that is not the same as a promise.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func limit(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.medium))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A note on what's underneath")
                .font(.headline)
            Text("EasyPlay doesn't run Windows games itself. It installs and drives Wine and Apple's Game Porting Toolkit, which do the actual work, and it credits them properly. Bottles shows the isolated Windows environments it creates — one per game, so a game that breaks its own setup can be deleted without touching anything else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Bottles") { model.screen = .bottles }
                .buttonStyle(.link)
                .padding(.top, 2)
        }
    }

    private struct StepRow: View {
        let number: Int
        let step: Step
        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(.tint.opacity(0.15)).frame(width: 34, height: 34)
                    Text("\(number)").font(.headline).foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: step.icon).foregroundStyle(.tint)
                        Text(step.title).font(.title3.weight(.semibold))
                    }
                    Text(step.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = step.action {
                        Button(action.label) { model.screen = action.screen }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }
}
