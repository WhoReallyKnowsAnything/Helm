import SwiftUI

/// The accents a person can pick (D-08). The colours behind each case are in `Ink.swatch(for:)`.
enum AccentChoice: String, CaseIterable, Identifiable {
    case lime, blue, indigo, purple, pink, red, yellow, green, mint, graphite

    /// The lime of the Terminal craft look (D-13), until a person picks another.
    static let `default` = AccentChoice.lime

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// The stored accent choice. `defaults` is a parameter, so tests never touch `.standard`.
struct AccentStore {
    static let key = "accentChoice"
    let defaults: UserDefaults

    var choice: AccentChoice {
        get { defaults.string(forKey: Self.key).flatMap(AccentChoice.init(rawValue:)) ?? .default }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

private struct KitAccentKey: EnvironmentKey {
    static let defaultValue = Ink.accent
}

extension EnvironmentValues {
    /// The resolved accent colours. Parts read this, never `Ink.accent` directly.
    var kitAccent: AccentSwatch {
        get { self[KitAccentKey.self] }
        set { self[KitAccentKey.self] = newValue }
    }
}

/// Sets `kitAccent` from the stored choice. `@AppStorage` redraws open windows when the choice changes, with no relaunch.
private struct AccentRoot: ViewModifier {
    @AppStorage(AccentStore.key) private var stored = AccentChoice.default.rawValue

    func body(content: Content) -> some View {
        content.environment(\.kitAccent, Ink.swatch(for: AccentChoice(rawValue: stored) ?? .default))
    }
}

extension View {
    /// Put this on the root view of every scene.
    func kitAccentRoot() -> some View { modifier(AccentRoot()) }
}
