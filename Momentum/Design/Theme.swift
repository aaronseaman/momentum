import SwiftUI
import MomentumKit

/// Calm, sparing color: blue = trends, green = money, orange = attention, gray = neutral.
enum Theme {
    static let trend = Color.blue
    static let money = Color.green
    static let attention = Color.orange
    static let neutral = Color.secondary

    static let cornerRadius: CGFloat = 22
    static let spacing: CGFloat = 16
    static let pagePadding: CGFloat = 20
    static let maxContentWidth: CGFloat = 720

    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static func color(for stage: ProjectStage) -> Color {
        switch stage {
        case .idea, .prototype: .gray
        case .mvp, .beta: .blue
        case .submitted: .orange
        case .live, .updating: .green
        case .paused, .abandoned: .secondary
        }
    }
}

struct CardModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.cardBackground)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.07))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardModifier(tint: tint)) }

    /// Centers content in a readable column on wide screens (iPad, Mac).
    func readableColumn() -> some View {
        frame(maxWidth: Theme.maxContentWidth).frame(maxWidth: .infinity)
    }
}

/// Big, friendly primary button. Large touch target, high contrast.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Quiet secondary button used for answers and options.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .foregroundStyle(selected ? .white : tint)
            .background((selected ? tint : tint.opacity(configuration.isPressed ? 0.22 : 0.12)), in: .rect(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(_ tint: Color) -> PrimaryButtonStyle { PrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static func soft(_ tint: Color, selected: Bool = false) -> SoftButtonStyle { SoftButtonStyle(tint: tint, selected: selected) }
}

extension Date {
    var relativeShort: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 60 { return "just now" }
        return formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
