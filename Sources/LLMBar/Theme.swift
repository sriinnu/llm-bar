import AppKit
import SwiftUI

// Themes change the look, never the structure: every theme shows the same tabs, header and
// views. A theme is a colour scheme, a ground, a font design, an accent and the status colours.
// Native follows the system; Terminal is always dark and monospaced; Editorial is always light,
// heavier type, one red accent.

enum ThemeID: String, CaseIterable, Identifiable {
    case native, slate, midnight, terminal, editorial
    var id: String { rawValue }
    var label: String {
        switch self {
        case .native: return "Native"
        case .slate: return "Slate"
        case .midnight: return "Midnight"
        case .terminal: return "Terminal"
        case .editorial: return "Editorial"
        }
    }
}

struct Theme {
    let id: ThemeID
    /// Native, Slate and Midnight use real AppKit controls (segmented pickers); Terminal and
    /// Editorial draw their own typographic tabs.
    var nativeControls: Bool { [.native, .slate, .midnight].contains(id) }
    let scheme: ColorScheme?        // nil = follow the system
    let ground: Color?              // nil = the popover's own material
    let fontDesign: Font.Design
    let accent: Color
    let live: Color                 // an agent is working here
    let warn: Color                 // uncommitted work
    let ready: Color                // safe to retire
    let danger: Color               // needs attention
    let hairline: Color
    let bigNumberWeight: Font.Weight
    let band: Color?                // content band behind lists (nil = none)

    static func of(_ id: ThemeID) -> Theme {
        switch id {
        case .native:
            return Theme(id: id, scheme: nil, ground: nil, fontDesign: .default,
                         accent: .accentColor, live: .green, warn: .orange, ready: .blue, danger: .red,
                         hairline: Color.primary.opacity(0.1), bigNumberWeight: .semibold,
                         band: Color(nsColor: .controlBackgroundColor))
        case .slate:
            // Cool grey-blue, follows the system appearance.
            return Theme(id: id, scheme: nil,
                         ground: dyn(0xEDF0F4, 0x1A2028), fontDesign: .default,
                         accent: dyn(0x3A6EA5, 0x8DB6E2),
                         live: dyn(0x2C8A57, 0x5FD38D), warn: dyn(0xB86E12, 0xF0A64B),
                         ready: dyn(0x3A6EA5, 0x8DB6E2), danger: dyn(0xB93A33, 0xF07167),
                         hairline: Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.09) }),
                         bigNumberWeight: .semibold,
                         band: dyn(0xF8FAFC, 0x222A34))
        case .midnight:
            // Deep blue-black, indigo accent, SF Rounded.
            return Theme(id: id, scheme: .dark, ground: hex(0x0B1020), fontDesign: .rounded,
                         accent: hex(0x8B8CFF), live: hex(0x4ADE80), warn: hex(0xFBBF24),
                         ready: hex(0x8B8CFF), danger: hex(0xFB7185),
                         hairline: Color.white.opacity(0.08), bigNumberWeight: .bold,
                         band: Color.white.opacity(0.04))
        case .terminal:
            return Theme(id: id, scheme: .dark, ground: Color(red: 0.055, green: 0.059, blue: 0.071),
                         fontDesign: .monospaced,
                         accent: Color(red: 0.56, green: 0.70, blue: 1.0),
                         live: Color(red: 0.29, green: 0.87, blue: 0.50),
                         warn: Color(red: 0.96, green: 0.65, blue: 0.14),
                         ready: Color(red: 0.56, green: 0.70, blue: 1.0),
                         danger: Color(red: 0.97, green: 0.44, blue: 0.44),
                         hairline: Color.white.opacity(0.09), bigNumberWeight: .bold,
                         band: Color.white.opacity(0.035))
        case .editorial:
            return Theme(id: id, scheme: .light, ground: .white, fontDesign: .default,
                         accent: Color(red: 0.78, green: 0.06, blue: 0.18),
                         live: Color(red: 0.12, green: 0.48, blue: 0.20),
                         warn: Color(red: 0.07, green: 0.07, blue: 0.07),
                         ready: Color(red: 0.78, green: 0.06, blue: 0.18),
                         danger: Color(red: 0.78, green: 0.06, blue: 0.18),
                         hairline: Color.black.opacity(0.14), bigNumberWeight: .heavy,
                         band: nil)
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.of(.native)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies a theme to a whole subtree: scheme, ground, font design, tint, and the environment value.
    @ViewBuilder
    func themed(_ t: Theme) -> some View {
        let base = self
            .environment(\.theme, t)
            .fontDesign(t.fontDesign)
            .tint(t.accent)
        if let scheme = t.scheme {
            if let ground = t.ground {
                base.environment(\.colorScheme, scheme).background(ground)
            } else {
                base.environment(\.colorScheme, scheme).background(.regularMaterial)
            }
        } else if let ground = t.ground {
            base.background(ground)
        } else {
            base.background(.regularMaterial)
        }
    }
}

/// A thin full-width rule in the theme's hairline colour.
struct Hairline: View {
    @Environment(\.theme) private var theme
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// The content band: lists sit on the control background (white in light mode) between hairlines,
/// the way native popovers and the approved boards separate content from chrome.
struct Band<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.band ?? .clear)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
    }
}

func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

private func nsHex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// A colour that resolves per appearance (light, dark) at draw time.
func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.isDark ? nsHex(dark) : nsHex(light) })
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
