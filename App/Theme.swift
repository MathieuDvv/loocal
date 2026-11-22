import SwiftUI
import UIKit

/// Monochrome palette. Every colour adapts between light (ink on paper) and dark (paper on ink).
enum Ink {
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let primary = adaptive(light: 0x111111, dark: 0xF4F4F4)
    static let secondary = adaptive(light: 0x6B6B6B, dark: 0x9A9A9A)
    static let tertiary = adaptive(light: 0x9A9A9A, dark: 0x6B6B6B)
    /// Soft fill for bubbles, selected tab pill and cards.
    static let fill = adaptive(light: 0xF2F2F2, dark: 0x1C1C1C)
    static let hairline = adaptive(light: 0xE8E8E8, dark: 0x262626)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Geist, the interface face. Named instances come from the bundled variable font.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .light, .thin, .ultraLight: "Geist-Light"
        case .medium: "Geist-Medium"
        case .semibold: "Geist-SemiBold"
        case .bold, .heavy, .black: "Geist-Bold"
        default: "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// Instrument Serif, for display moments only.
    static func serif(_ size: CGFloat, italic: Bool = false, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size, relativeTo: style)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

/// Small uppercase-free section label, Geist medium, muted.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.geist(13, .medium)).foregroundStyle(Ink.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary button: ink capsule with paper text.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(15, .medium))
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, 20).frame(minHeight: 50)
            .frame(maxWidth: .infinity)
            .background(Ink.primary, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Gentle press: a small squeeze and dim, released with a spring.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// A tap on this area closes the keyboard. Simultaneous, so buttons, links, scrolling
    /// and text selection inside keep working. Never apply it over a text field.
    func dismissesKeyboardOnTap() -> some View {
        contentShape(.rect).simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
    }

    /// Fade and rise into place once `shown` turns true, optionally staggered.
    func rise(_ shown: Bool, delay: Double = 0, distance: CGFloat = 12) -> some View {
        self.opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : distance)
            .blur(radius: shown ? 0 : 4)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(delay), value: shown)
    }
}
