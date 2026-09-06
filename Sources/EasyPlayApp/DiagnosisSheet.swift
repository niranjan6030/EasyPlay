import SwiftUI
import EasyPlayKit

/// What the user sees instead of a Wine log.
///
/// The raw log is still there, one disclosure triangle away — hiding it entirely
/// would be its own kind of unhelpful — but it is never the first thing shown.
struct DiagnosisSheet: View {
    let diagnoses: [Diagnosis]
    var game: InstalledGame?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(diagnoses.first?.title ?? "Something went wrong")
                    .font(.title3.weight(.semibold))
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(diagnoses) { diagnosis in
                        VStack(alignment: .leading, spacing: 10) {
                            if diagnosis.id != diagnoses.first?.id {
                                Text(diagnosis.title).font(.headline)
                            }

                            Text(diagnosis.explanation)
                                .fixedSize(horizontal: false, vertical: true)

                            if let remedy = diagnosis.remedy, let game {
                                Button {
                                    model.apply(remedy, to: game)
                                    dismiss()
                                } label: {
                                    Label(remedy.buttonTitle, systemImage: "wrench.and.screwdriver")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if let evidence = diagnosis.evidence, !evidence.isEmpty {
                                DisclosureGroup("Technical details", isExpanded: $showingDetails) {
                                    Text(evidence)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(.quaternary.opacity(0.5),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 400)
    }
}
