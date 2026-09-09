import Foundation
import EasyPlayKit

/// The advisor's value is entirely in what it refuses to claim. These tests
/// guard that first and the matching second.
enum AdvisorTests {
    static func run() throws {
        let catalog = GameCatalog()
        let advisor = CompatibilityAdvisor()

        Harness.suite("Game catalogue") {
            Harness.expect(catalog.loadError == nil, "the catalogue loads: \(String(describing: catalog.loadError))")
            Harness.expect(catalog.entries.count > 25, "it has a useful number of entries (\(catalog.entries.count))")

            let ids = catalog.entries.map(\.id)
            Harness.expectEqual(Set(ids).count, ids.count, "entry ids are unique")

            // Provenance is the whole product. An entry without a source is a
            // rumour, and a rumour is what this feature exists to avoid.
            let unsourced = catalog.entries.filter { $0.source.trimmingCharacters(in: .whitespaces).isEmpty }
            Harness.expect(unsourced.isEmpty, "every entry cites a source (\(unsourced.map(\.id)))")
            let undated = catalog.entries.filter { $0.lastReviewed.isEmpty }
            Harness.expect(undated.isEmpty, "every entry records when it was reviewed")

            // Nothing may be rated as working purely on a hunch: a runsGreat
            // verdict has to be backed by a native build or a real preset.
            let overclaimed = catalog.entries.filter {
                $0.verdict == .runsGreat && !$0.macNative && $0.presetID == nil
            }
            Harness.expect(overclaimed.isEmpty,
                           "nothing claims to run great without a native build or a preset (\(overclaimed.map(\.id)))")

            // And anything with kernel anti-cheat must be refused outright.
            let missed = catalog.entries.filter {
                ($0.antiCheat?.isKernelLevel ?? false) && $0.verdict != .notSupported
            }
            Harness.expect(missed.isEmpty, "kernel anti-cheat always means not supported (\(missed.map(\.id)))")
        }

        Harness.suite("Question parsing") {
            let cases: [(String, String)] = [
                ("can I run Elden Ring?", "elden ring"),
                ("will Baldur's Gate 3 work on my mac", "baldur's gate 3"),
                ("does cyberpunk 2077 run on apple silicon", "cyberpunk 2077"),
                ("what about skyrim", "skyrim"),
                ("I want to play Hades on my MacBook", "hades"),
            ]
            for (question, expected) in cases {
                let extracted = CompatibilityAdvisor.extractGameName(from: question)
                Harness.expect(extracted.contains(expected.replacingOccurrences(of: "'", with: "")) || extracted.contains(expected),
                               "\"\(question)\" -> \"\(extracted)\"")
            }
        }

        Harness.suite("Matching") {
            Harness.expectEqual(catalog.bestMatch("elden ring")?.id, "elden-ring", "exact title matches")
            Harness.expectEqual(catalog.bestMatch("bg3")?.id, "baldurs-gate-3", "an alias matches")
            Harness.expectEqual(catalog.bestMatch("cyberpunck 2077")?.id, "cyberpunk-2077", "a typo still matches")
            Harness.expectEqual(catalog.bestMatch("skyrim")?.id, "skyrim-special-edition",
                                "a partial title matches the full one")
            // Roman numerals are how these titles are actually written.
            Harness.expectEqual(catalog.bestMatch("civilization 6")?.id, "civilization-vi",
                                "roman numerals and digits are treated alike")
            // The important negative: nonsense must not match anything.
            Harness.expect(catalog.bestMatch("zzzz nonexistent game") == nil,
                           "an unknown game matches nothing rather than the nearest title")
        }

        Harness.suite("Advice") {
            let elden = advisor.answer(to: "can I run Elden Ring?")
            Harness.expect(elden.verdict == .willNotRun, "kernel anti-cheat is a definite no")
            Harness.expect(elden.source != nil, "and it says where that comes from")

            let bg3 = advisor.answer(to: "baldurs gate 3")
            Harness.expect(bg3.verdict == .playNatively,
                           "a native Mac build is reported instead of a Wine workaround")

            let ride = advisor.answer(to: "ride 4")
            Harness.expect(ride.verdict == .hasPreset, "a game with a preset says so")
            Harness.expect(ride.actions.contains { if case .installPreset = $0.kind { return true }; return false },
                           "and offers the preset as an action")

            let cs2 = advisor.answer(to: "counter-strike 2")
            Harness.expect(cs2.verdict == .noKnownBlocker,
                           "VAC is not kernel-level, so it is not treated as a blocker")

            let unknown = advisor.answer(to: "some game that does not exist at all")
            Harness.expect(unknown.verdict == .unknown, "an unknown game is admitted, not guessed at")
            Harness.expect(unknown.source == nil, "an unknown answer cites no source, because it has none")
            Harness.expect(!unknown.actions.isEmpty, "but it still points at somewhere useful to look")

            let empty = advisor.answer(to: "hello")
            Harness.expect(empty.verdict == .unknown, "a greeting asks for a game name")

            // The property that matters most: no answer may claim a game runs
            // unless it is native or has a preset behind it.
            for entry in catalog.entries {
                let advice = advisor.advice(for: entry)
                if advice.verdict == .playNatively { Harness.expect(entry.macNative, "\(entry.id): native claim is backed") }
                if advice.verdict == .hasPreset { Harness.expect(entry.presetID != nil, "\(entry.id): preset claim is backed") }
                if advice.verdict != .unknown {
                    Harness.expect(advice.source != nil, "\(entry.id): every definite answer has a source")
                }
            }
        }
    }
}
