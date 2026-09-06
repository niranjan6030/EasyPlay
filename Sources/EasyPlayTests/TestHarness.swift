import Foundation

/// A deliberately tiny test harness.
///
/// XCTest and swift-testing both ship with Xcode, not with the Command Line
/// Tools, so a package that must build on a machine with only the CLT installed
/// cannot depend on either. Rather than skip tests, the assertions live here.
/// Each one maps one-to-one onto `#expect`, so moving to swift-testing later is
/// a find-and-replace.
enum Harness {
    private(set) static var passed = 0
    private(set) static var failures: [String] = []
    private static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
            print("  \u{001B}[31m✘ threw \(error)\u{001B}[0m")
        }
    }

    static func expect(_ condition: Bool, _ description: String,
                       file: String = #fileID, line: Int = #line) {
        if condition {
            passed += 1
            print("  \u{001B}[32m✔\u{001B}[0m \(description)")
        } else {
            failures.append("\(currentSuite): \(description)  (\(file):\(line))")
            print("  \u{001B}[31m✘ \(description)\u{001B}[0m  \u{001B}[2m\(file):\(line)\u{001B}[0m")
        }
    }

    /// Convenience for the common "these should be equal" case, so a failure
    /// reports both values instead of just "false".
    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String,
                                          file: String = #fileID, line: Int = #line) {
        expect(actual == expected,
               actual == expected ? description : "\(description) — got \(actual), expected \(expected)",
               file: file, line: line)
    }

    static func summarise() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\u{001B}[32m\(passed) checks passed.\u{001B}[0m\n")
            return 0
        }
        print("\u{001B}[31m\(failures.count) failed, \(passed) passed.\u{001B}[0m")
        failures.forEach { print("  • \($0)") }
        print("")
        return 1
    }
}
