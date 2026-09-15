import Foundation
import EasyPlayKit

/// The classifier is the difference between "it didn't work" and "here is what
/// to press". These cover the translation, not Wine itself.
enum LogClassifierTests {
    static func run() throws {
        Harness.suite("Log classification") {
            let missingRuntime = #"0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"Z:\\game\\RIDE4.exe") not found"#
            let generic = LogClassifier().classify(log: missingRuntime, exitCode: 53)
            Harness.expect(!generic.isEmpty, "a missing C++ runtime is recognised")
            Harness.expect(generic.first?.remedy == .installWinetricksVerb("vcrun2019"),
                           "and it offers to install the runtime")

            // A per-game explanation beats the generic one, so it must come first.
            if let recipe = try? RecipeLibrary().recipe(id: "ride-4") {
                let specific = LogClassifier(recipe: recipe).classify(log: missingRuntime, exitCode: 1)
                Harness.expect(specific.first?.id.hasPrefix("recipe:") == true,
                               "a preset's own diagnosis outranks the generic one")
            }

            let antiCheat = LogClassifier().classify(log: "EasyAntiCheat: failed to load driver", exitCode: 1).first
            Harness.expectEqual(antiCheat?.title, "Blocked by anti-cheat", "anti-cheat is recognised")
            Harness.expect(antiCheat?.remedy == nil,
                           "no fix is offered for anti-cheat, because offering one would be a lie")

            let vulkan = LogClassifier().classify(log: "err:winediag:vulkan_init Failed to load Vulkan", exitCode: 1)
            Harness.expect(vulkan.first?.remedy == .switchGraphics(.d3dMetal),
                           "a Vulkan failure suggests switching to D3DMetal")

            // Verbatim from a real Heaven run: this Wine build has no Vulkan at
            // all, and the message arrives on the err:vulkan channel, which an
            // earlier version of the pattern did not cover.
            let realVulkanFailure = "0024:err:vulkan:get_vulkan_driver Wine was built without Vulkan support."
            let vulkanDiagnoses = LogClassifier().classify(log: realVulkanFailure, exitCode: 1)
            Harness.expect(vulkanDiagnoses.first?.remedy == .switchGraphics(.d3dMetal),
                           "Wine's real 'built without Vulkan support' message is recognised")

            let unknown = LogClassifier().classify(log: "something inscrutable", exitCode: 134)
            Harness.expectEqual(unknown.count, 1, "an unrecognised failure still says something")
            Harness.expectEqual(unknown.first?.id, "unknown-failure", "and is labelled as unrecognised")

            Harness.expect(LogClassifier().classify(log: "", exitCode: 0).isEmpty,
                           "a clean run produces no diagnoses")

            let noisy = "prefix noise\n0024:err:module:import_dll Library MSVCP140.dll not found\nmore noise"
            Harness.expectEqual(LogClassifier().classify(log: noisy, exitCode: 1).first?.evidence,
                                "0024:err:module:import_dll Library MSVCP140.dll not found",
                                "evidence is the whole log line, not just the matched fragment")

            // A real log captured from a successful 7-Zip install. Wine always
            // fails to build Start Menu shortcuts on macOS, and that noise must
            // not be mistaken for a problem — a launcher that cries wolf on every
            // successful install is worse than one that says nothing.
            let realSuccessfulInstall = """
            esync: up and running.
            00f0:err:menubuilder:cx_wineshelllink wineshelllink returned -1073741772
            00f0:err:menubuilder:InvokeShellLinker failed to build the menu
            00f8:err:menubuilder:cx_wineshelllink wineshelllink returned -1073741772
            00f8:err:menubuilder:InvokeShellLinker failed to build the menu
            """
            Harness.expect(LogClassifier().classify(log: realSuccessfulInstall, exitCode: 0).isEmpty,
                           "Wine's harmless shortcut-builder errors raise no false alarm")

            Harness.expect(Diagnosis.Remedy(action: "reboot:mac") == nil,
                           "unknown remedy actions are rejected")
            Harness.expect(Diagnosis.Remedy(action: "graphics:nonsense") == nil,
                           "a remedy naming an unknown translator is rejected")
            Harness.expect(Diagnosis.Remedy(action: "steam:signin") == .signInToSteam,
                           "known remedy actions parse")
            Harness.expect(Diagnosis.Remedy(action: "steam:start") == nil,
                           "the old start-Steam remedy is gone, because it could never work")
        }
    }
}
