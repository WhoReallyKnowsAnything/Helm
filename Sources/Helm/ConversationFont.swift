import AppKit
import SwiftUI

/// The family and size of conversation text (the D-13 exception). Every other role stays SF Mono at 12 or 13 pt.
/// A role's size is the setting plus the role's `KitType` size minus 13, so label and meta stay 1 pt under body.
/// `defaults` is a parameter, so tests never touch `.standard`.
struct ConversationFont: Hashable {
    static let familyKey = "conversationFontFamily"
    static let sizeKey = "conversationFontSize"
    static let defaultFamily = "SF Mono"
    static let defaultSize = 13.0
    static let sizes = 10.0...24.0
    static let `default` = ConversationFont(family: defaultFamily, size: defaultSize)

    let family: String
    let size: Double

    init(family: String, size: Double) {
        self.family = family
        self.size = min(max(size, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    init(defaults: UserDefaults) {
        self.init(family: defaults.string(forKey: Self.familyKey) ?? Self.defaultFamily,
                  size: defaults.object(forKey: Self.sizeKey) as? Double ?? Self.defaultSize)
    }

    /// An uninstalled family gives the system monospaced face.
    func nsFont(for role: KitType, strong: Bool = false, italic: Bool = false) -> NSFont {
        let semibold = strong || role == .title || role == .section
        let points = CGFloat(size) + role.nsFont.pointSize - CGFloat(Self.defaultSize)
        var font = NSFont.monospacedSystemFont(ofSize: points, weight: semibold ? .semibold : .regular)
        if family != Self.defaultFamily,
           let custom = NSFontManager.shared.font(withFamily: family, traits: semibold ? .boldFontMask : [], weight: 5, size: points) {
            font = custom
        }
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    func font(for role: KitType) -> Font { Font(nsFont(for: role)) }

    static let promptLines = 6

    /// The height that shows `promptLines` lines of a message unclipped, on the 4 pt grid and never under the fixed cap.
    var promptFieldMaxHeight: CGFloat {
        let font = nsFont(for: .body)
        let lines = CGFloat(Self.promptLines) * (font.ascender - font.descender + font.leading)
        return max(Metric.promptFieldMaxHeight, (lines / 4).rounded(.up) * 4)
    }

    /// The default first, then the monospaced families, then the rest. It reads font descriptors only (no font is built),
    /// which Core Text allows on any thread, so Settings builds it off the main thread.
    static func loadFamilies() -> [String] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var fixed = Set<String>(), other = Set<String>()
        for descriptor in descriptors {
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix("."), family != defaultFamily else { continue }
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            if symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0 { fixed.insert(family) } else { other.insert(family) }
        }
        other.subtract(fixed)
        let sorted = { (names: Set<String>) in names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        return [defaultFamily] + sorted(fixed) + sorted(other)
    }
}

private struct ConversationFontModifier: ViewModifier {
    let role: KitType
    @AppStorage(ConversationFont.familyKey) private var family = ConversationFont.defaultFamily
    @AppStorage(ConversationFont.sizeKey) private var size = ConversationFont.defaultSize

    func body(content: Content) -> some View {
        content.font(ConversationFont(family: family, size: size).font(for: role))
    }
}

extension View {
    /// Like `kitType`, for text a person reads or writes in a conversation. It follows the Settings choice at once.
    func conversationFont(_ role: KitType) -> some View { modifier(ConversationFontModifier(role: role)) }
}
