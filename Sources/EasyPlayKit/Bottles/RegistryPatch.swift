import Foundation

/// A batch of registry values, written to a bottle in one Wine invocation.
///
/// Applying a preset used to launch Wine once per setting — a Windows version,
/// Retina mode, and a handful of DLL overrides, each paying Wine's start-up
/// cost. Importing one `.reg` file applies all of them in a single launch.
public struct RegistryPatch: Equatable {
    public struct Value: Equatable {
        public let key: String
        public let name: String
        public let data: String
    }

    public private(set) var values: [Value] = []

    public init() {}

    public mutating func set(_ key: String, _ name: String, _ data: String) {
        values.removeAll { $0.key == key && $0.name == name }
        values.append(Value(key: key, name: name, data: data))
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Everything a preset contributes to the registry.
    public static func forRecipe(_ recipe: Recipe) -> RegistryPatch {
        var patch = RegistryPatch()
        patch.set(#"HKEY_CURRENT_USER\Software\Wine"#, "Version", recipe.bottle.windowsVersion)
        if recipe.bottle.retinaMode {
            patch.set(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", "y")
        }
        for (dll, order) in recipe.dllOverrides.sorted(by: { $0.key < $1.key }) {
            patch.set(#"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#, dll, order)
        }
        return patch
    }

    /// The patch as a `.reg` file, grouped by key in first-seen order.
    public var regFileContents: String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var seen: [String] = []
        for value in values where !seen.contains(value.key) { seen.append(value.key) }
        for key in seen {
            lines.append("[\(key)]")
            for value in values where value.key == key {
                lines.append("\"\(Self.escape(value.name))\"=\"\(Self.escape(value.data))\"")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// `.reg` strings escape backslashes and quotes.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
