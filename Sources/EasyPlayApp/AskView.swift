import SwiftUI
import EasyPlayKit

/// The conversational front door: "can I run this?"
///
/// It looks like a chatbot and behaves like a reference book. Every answer comes
/// from the bundled catalogue with its source attached, and when there is no
/// entry it says so rather than improvising — a confident wrong "yes" here costs
/// someone a purchase and a very long download.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var question = ""
    @State private var turns: [Turn] = []
    @FocusState private var inputFocused: Bool

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let advice: CompatibilityAdvisor.Advice
    }

    private let suggestions = ["Can I run Elden Ring?", "Baldur's Gate 3", "RIDE 4", "Skyrim"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if turns.isEmpty { intro }
                        ForEach(turns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(turn.question)
                                    .font(.callout)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                AnswerCard(advice: turn.advice)
                            }
                            .id(turn.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: turns.count) {
                    withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Ask about a game…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($inputFocused)
                    .onSubmit(ask)

                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .navigationTitle("Ask")
        .onAppear { inputFocused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Will it run on your Mac?")
                .font(.title2.weight(.semibold))
            Text("Ask about a game before you buy it. EasyPlay answers from a catalogue it ships with, and tells you where each answer comes from. If it doesn't know a game, it says so instead of guessing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        question = suggestion
                        ask()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 8)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        turns.append(Turn(question: text, advice: model.advisor.answer(to: text)))
        question = ""
    }
}

private struct AnswerCard: View {
    let advice: CompatibilityAdvisor.Advice
    @Environment(AppModel.self) private var model
    @State private var showingNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(colour)
                Text(advice.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(advice.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !advice.notes.isEmpty {
                DisclosureGroup("Details", isExpanded: $showingNotes) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(advice.notes, id: \.self) { note in
                            Text("• \(note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }

            if !advice.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(advice.actions) { action in
                        Button(action.title) { perform(action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            if let source = advice.source {
                // The provenance line is deliberately always visible. An answer
                // you cannot check is not much better than a guess.
                Text("Source: \(source)\(advice.entry.map { " · reviewed \($0.lastReviewed)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !advice.alternatives.isEmpty {
                Text("Did you mean: \(advice.alternatives.map(\.title).joined(separator: ", "))?")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Rectangle().fill(colour).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func perform(_ action: CompatibilityAdvisor.Advice.Action) {
        switch action.kind {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .installPreset(let recipeID):
            model.startInstall(withPreset: recipeID)
        }
    }

    private var icon: String {
        switch advice.verdict {
        case .playNatively: return "apple.logo"
        case .hasPreset: return "checkmark.seal.fill"
        case .willNotRun: return "xmark.octagon.fill"
        case .noKnownBlocker: return "questionmark.circle.fill"
        case .unknown: return "magnifyingglass.circle.fill"
        }
    }

    private var colour: Color {
        switch advice.verdict {
        case .playNatively, .hasPreset: return .green
        case .willNotRun: return .red
        case .noKnownBlocker: return .orange
        case .unknown: return .secondary
        }
    }
}
