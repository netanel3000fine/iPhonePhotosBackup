import SwiftUI
import AppKit

/// Localizes a string key according to the user's selected language setting.
func l10n(_ key: String, lang: String? = nil) -> String {
    let currentLang = lang ?? (UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String) ?? (UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
    let languageCode = currentLang.hasPrefix("he") ? "he" : "en"
    
    if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        let val = bundle.localizedString(forKey: key, value: key, table: nil)
        if val != key { return val }
    }
    return NSLocalizedString(key, comment: "")
}

// MARK: - Appearance Selection

enum AppAppearance: String, CaseIterable, Identifiable {
    case liquidGlass = "liquidGlass"

    var id: String { rawValue }

    /// Modern design using rounded glass controls and spring motion.
    var isModernDesign: Bool { true }

    var displayName: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        }
    }

    var description: String {
        switch self {
        case .liquidGlass:
            return "Native macOS sidebar layout. Clean frosted glass panels, single borders, and a native sidebar navigator."
        }
    }
}

enum ThemeColor: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case grey = "Grey"
    case purple = "Purple"
    case yellow = "Yellow"
    case red = "Red"
    case blue = "Blue"
    case lightBlue = "Light Blue"
    case green = "Green"
    case orange = "Orange"
    
    var id: String { self.rawValue }
    
    var color: Color? {
        switch self {
        case .default: return nil
        case .grey: return Color.black
        case .purple: return .purple
        case .yellow: return .yellow
        case .red: return .red
        case .blue: return .blue
        case .lightBlue: return .cyan
        case .green: return .green
        case .orange: return .orange
        }
    }
}

// MARK: - Theme Tokens

struct AppTheme: Equatable {
    let windowMaterialOpacity: Double
    let windowTintOpacity: Double
    let windowHighlightTop: Double
    let windowHighlightMid: Double
    let windowShadowBottom: Double
    let windowAccentGlow: Double
    let windowTopBarHighlight: Double

    let cardMaterial: NSVisualEffectView.Material
    let cardMaterialOpacity: Double
    let cardTintOpacity: Double
    let cardBorderOpacity: Double
    let cardShadowOpacity: Double
    let cardCornerRadius: CGFloat
    let surfaceHighlightTop: Double

    let panelMaterial: NSVisualEffectView.Material
    let panelTintOpacity: Double
    let panelInnerTintOpacity: Double

    let tabBarMaterial: NSVisualEffectView.Material
    let tabBarTintOpacity: Double
    let tabBarCornerRadius: CGFloat
    let useNativeGlassTabBar: Bool

    let frameCornerRadius: CGFloat
    let framePadding: CGFloat
    let frameBorderOpacity: Double
    let usesFloatingFrame: Bool

    let bottomBarMaterialOpacity: Double
    let bottomBarGradientTop: Double
    let bottomBarGradientBottom: Double
    let separatorLeading: Double
    let separatorCenter: Double
    let separatorTrailing: Double
    let titleBarGradientTop: Double
    let titleBarGradientBottom: Double

    let animatesTabChanges: Bool
    let animatesContentChanges: Bool
    let enablesHoverScale: Bool
    let tabSpringResponse: Double
    let tabSpringDamping: Double

    let innerFramePadding: CGFloat
    let buttonPaddingHorizontal: CGFloat
    let buttonPaddingVertical: CGFloat

    static func theme(for appearance: AppAppearance) -> AppTheme {
        switch appearance {
        case .liquidGlass:
            return AppTheme(
                windowMaterialOpacity: 0.02,
                windowTintOpacity: 0.0,
                windowHighlightTop: 0.45,
                windowHighlightMid: 0.08,
                windowShadowBottom: 0.02,
                windowAccentGlow: 0.0,
                windowTopBarHighlight: 0.0,
                cardMaterial: .selection,
                cardMaterialOpacity: 0.18,
                cardTintOpacity: 0.0,
                cardBorderOpacity: 0.10,
                cardShadowOpacity: 0.02,
                cardCornerRadius: 12,
                surfaceHighlightTop: 0.35,
                panelMaterial: .selection,
                panelTintOpacity: 0.0,
                panelInnerTintOpacity: 0.0,
                tabBarMaterial: .selection,
                tabBarTintOpacity: 0.0,
                tabBarCornerRadius: 8,
                useNativeGlassTabBar: true,
                frameCornerRadius: 0,
                framePadding: 0,
                frameBorderOpacity: 0.0,
                usesFloatingFrame: false,
                bottomBarMaterialOpacity: 0.20,
                bottomBarGradientTop: 0.05,
                bottomBarGradientBottom: 0.15,
                separatorLeading: 0.0,
                separatorCenter: 0.05,
                separatorTrailing: 0.0,
                titleBarGradientTop: 0.0,
                titleBarGradientBottom: 0.0,
                animatesTabChanges: true,
                animatesContentChanges: true,
                enablesHoverScale: true,
                tabSpringResponse: 0.25,
                tabSpringDamping: 0.75,
                innerFramePadding: 8,
                buttonPaddingHorizontal: 14,
                buttonPaddingVertical: 7
            )
        }
    }
}

// MARK: - Button Roles

enum AppButtonRole {
    case primary
    case secondary
    case destructive
    case plain
    case text
}

// MARK: - Environment

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.theme(for: .liquidGlass)
}

private struct AppAppearanceKey: EnvironmentKey {
    static let defaultValue = AppAppearance.liquidGlass
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }

    var appAppearance: AppAppearance {
        get { self[AppAppearanceKey.self] }
        set { self[AppAppearanceKey.self] = newValue }
    }
}

// MARK: - Button Styles

struct GlassButtonStyle: ButtonStyle {
    let role: AppButtonRole
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTheme) private var theme
    @Environment(\.appAppearance) private var appearance

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        // Note: native .buttonStyle(.glass) / .buttonStyle(.glassProminent) are applied
        // upstream in AppButtonModifier so they wrap the full Button, not just the label.
        // This style handles the non-liquidGlass appearance and any residual direct uses.
        configuration.label
            .font(font)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(foregroundColor)
            .background(background(isPressed: configuration.isPressed, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 0.5)
            }
            .shadow(color: shadowColor, radius: role == .primary ? 4 : 2, y: role == .primary ? 2 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : (isHovered ? 1.015 : 1.0))
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.8)) {
                    isHovered = hovering
                }
            }
            .animation(.spring(response: 0.20, dampingFraction: 0.75), value: configuration.isPressed)
            .opacity(isEnabled ? 1.0 : 0.42)
    }

    private var font: Font {
        switch role {
        case .text: return .caption
        default: return .system(.callout, design: .rounded).weight(.semibold)
        }
    }

    private var horizontalPadding: CGFloat {
        switch role {
        case .text: return 5
        case .plain: return 8
        default: return theme.buttonPaddingHorizontal
        }
    }

    private var verticalPadding: CGFloat {
        switch role {
        case .text: return 3
        case .plain: return 6
        default: return theme.buttonPaddingVertical
        }
    }

    private var foregroundColor: Color {
        if appearance == .liquidGlass {
            switch role {
            case .primary: return .white
            case .destructive: return Color.red
            case .text: return .secondary
            default: return .primary
            }
        }
        switch role {
        case .primary: return .white
        case .destructive: return Color(red: 1.0, green: 0.82, blue: 0.82)
        case .text: return .secondary
        default: return .primary
        }
    }

    @ViewBuilder
    private func background(isPressed: Bool, isHovered: Bool) -> some View {
        if appearance == .liquidGlass {
            switch role {
            case .primary:
                LinearGradient(
                    colors: [
                        Color.accentColor,
                        Color.accentColor.opacity(0.85)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(isPressed ? 0.85 : 1.0)
            case .destructive:
                ZStack {
                    VisualEffectView(material: .selection, blendingMode: .withinWindow)
                        .opacity(isPressed ? 0.30 : (isHovered ? 0.22 : 0.14))
                    Color.red.opacity(isPressed ? 0.18 : (isHovered ? 0.10 : 0.05))
                }
            case .secondary, .plain:
                ZStack {
                    VisualEffectView(material: .selection, blendingMode: .withinWindow)
                        .opacity(isPressed ? 0.35 : (isHovered ? 0.28 : 0.18))
                    Color.white.opacity(isPressed ? 0.05 : (isHovered ? 0.02 : 0.0))
                }
            case .text:
                Color.clear
            }
        } else {
            switch role {
            case .primary:
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.accentColor,
                            Color.accentColor.opacity(0.78),
                            Color.cyan.opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
                .opacity(isPressed ? 0.88 : 1.0)
            case .destructive:
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.55)
                    Color.red.opacity(isPressed ? 0.34 : 0.24)
                }
            case .secondary, .plain:
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.62)
                    Color.white.opacity(isPressed ? 0.14 : 0.08)
                }
            case .text:
                Color.clear
            }
        }
    }

    private var borderGradient: LinearGradient {
        if appearance == .liquidGlass {
            switch role {
            case .primary:
                return LinearGradient(
                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .destructive:
                return LinearGradient(
                    colors: [Color.red.opacity(0.35), Color.red.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .text:
                return LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
            default:
                return LinearGradient(
                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        switch role {
        case .primary:
            return LinearGradient(
                colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .destructive:
            return LinearGradient(
                colors: [Color.red.opacity(0.55), Color.red.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .text:
            return LinearGradient(colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(
                colors: [Color.white.opacity(0.42), Color.white.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowColor: Color {
        if appearance == .liquidGlass {
            switch role {
            case .primary: return Color.accentColor.opacity(0.12)
            case .destructive: return Color.red.opacity(0.08)
            default: return Color.black.opacity(0.02)
            }
        }
        switch role {
        case .primary: return Color.accentColor.opacity(0.35)
        case .destructive: return Color.red.opacity(0.22)
        default: return Color.black.opacity(0.12)
        }
    }
}

private struct AppButtonModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance

    let role: AppButtonRole
    let size: ControlSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearance.isModernDesign {
            content
                .buttonStyle(GlassButtonStyle(role: role))
                .controlSize(size == .large ? .regular : size)
        } else {
            switch role {
            case .primary:
                content.buttonStyle(.borderedProminent).controlSize(size)
            case .secondary, .destructive:
                content.buttonStyle(.bordered).controlSize(size)
            case .plain, .text:
                content.buttonStyle(.plain).controlSize(size)
            }
        }
    }
}

extension View {
    func appButton(_ role: AppButtonRole, size: ControlSize = .regular) -> some View {
        modifier(AppButtonModifier(role: role, size: size))
    }

    func appToggleStyle() -> some View {
        modifier(AppToggleStyleModifier())
    }
}

private struct AppToggleStyleModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance

    func body(content: Content) -> some View {
        if appearance.isModernDesign {
            content.toggleStyle(.switch)
        } else {
            content.toggleStyle(.checkbox)
        }
    }
}

// MARK: - Surface Modifiers

extension View {
    func themedCard() -> some View {
        modifier(ThemedCardModifier())
    }

    func themedPanel(cornerRadius: CGFloat? = nil, inner: Bool = false) -> some View {
        modifier(ThemedPanelModifier(cornerRadius: cornerRadius, inner: inner))
    }

    func themedWindowBackground() -> some View {
        modifier(ThemedWindowBackgroundModifier())
    }

    func themedBottomBarBackground() -> some View {
        modifier(ThemedBottomBarModifier())
    }

    func themedTitleBarBackground() -> some View {
        modifier(ThemedTitleBarModifier())
    }

    func themedTabBarBackground() -> some View {
        modifier(ThemedTabBarBackgroundModifier())
    }

    func themedAppFrame() -> some View {
        modifier(ThemedAppFrameModifier())
    }

    func themedSheetChrome() -> some View {
        modifier(ThemedSheetChromeModifier())
    }
}

private struct ThemedSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let material: NSVisualEffectView.Material
    let tintOpacity: Double
    let materialOpacity: Double
    let borderOpacity: Double
    let shadowOpacity: Double
    let highlightTop: Double

    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default

    func body(content: Content) -> some View {
        content
            // Thin text-shadow on all content for contrast over frosted glass
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.20), radius: 0, x: 0, y: 0.5)
            .background {
                if appearance == .liquidGlass {
                    // Ultra-thin frosted glass card with real-time blur in both light & dark modes
                    let accentColor: Color? = themeColor == .default ? nil : themeColor.color
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        if colorScheme == .light {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.25))
                        }
                        if let accent = accentColor {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.05))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                accentColor.map { $0.opacity(0.25) } ?? (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)),
                                lineWidth: 1.0
                            )
                    }
                    .shadow(color: (accentColor ?? .black).opacity(
                        accentColor != nil ? 0.18 : (colorScheme == .dark ? 0.35 : 0.08)
                    ), radius: 8, x: 0, y: 4)
                } else {
                    ZStack {
                        VisualEffectView(material: material, blendingMode: .withinWindow)
                            .opacity(materialOpacity)
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(tintOpacity)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(highlightTop),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(borderOpacity),
                                        Color.white.opacity(borderOpacity * 0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: Color.black.opacity(shadowOpacity), radius: 16, x: 0, y: 8)
                }
            }
    }
}

private struct ThemedAppFrameModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        if theme.usesFloatingFrame {
            content
                .padding(theme.innerFramePadding)
                .background {
                    ZStack {
                        VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                            .opacity(0.58)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.04),
                                Color.black.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: theme.frameCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.frameCornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(theme.frameBorderOpacity),
                                        Color.white.opacity(theme.frameBorderOpacity * 0.25),
                                        Color.white.opacity(theme.frameBorderOpacity * 0.55)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.25
                            )
                    }
                    .shadow(color: Color.black.opacity(0.28), radius: 36, x: 0, y: 18)
                }
                .padding(theme.framePadding)
        } else {
            content
        }
    }
}

private struct ThemedSheetChromeModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        if appearance.isModernDesign {
            content
                .padding(18)
                .background {
                    ZStack {
                        VisualEffectView(material: .popover, blendingMode: .withinWindow)
                            .opacity(0.72)
                        Color.white.opacity(0.05)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(theme.cardBorderOpacity), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.22), radius: 28, y: 14)
                .padding(24)
        } else {
            content
        }
    }
}

private struct ThemedCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.modifier(
            ThemedSurfaceModifier(
                cornerRadius: theme.cardCornerRadius,
                material: theme.cardMaterial,
                tintOpacity: theme.cardTintOpacity,
                materialOpacity: theme.cardMaterialOpacity,
                borderOpacity: theme.cardBorderOpacity,
                shadowOpacity: theme.cardShadowOpacity,
                highlightTop: theme.surfaceHighlightTop
            )
        )
    }
}

private struct ThemedPanelModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    let cornerRadius: CGFloat?
    let inner: Bool

    func body(content: Content) -> some View {
        content.modifier(
            ThemedSurfaceModifier(
                cornerRadius: cornerRadius ?? theme.cardCornerRadius,
                material: theme.panelMaterial,
                tintOpacity: inner ? theme.panelInnerTintOpacity : theme.panelTintOpacity,
                materialOpacity: theme.cardMaterialOpacity,
                borderOpacity: theme.cardBorderOpacity,
                shadowOpacity: theme.cardShadowOpacity,
                highlightTop: theme.surfaceHighlightTop
            )
        )
    }
}

private struct ThemedWindowBackgroundModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.appAppearance) private var appearance
    @AppStorage("themeColor") private var themeColor: ThemeColor = .default

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if appearance == .liquidGlass {
                        // Liquid Glass: clean translucent frosted glass behind the window
                        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                        if let color = themeColor.color {
                            color.opacity(0.06)
                        }
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear, .black.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                            .opacity(theme.windowMaterialOpacity)
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(theme.windowTintOpacity)
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.windowHighlightTop),
                                Color.white.opacity(theme.windowHighlightMid),
                                Color.black.opacity(theme.windowShadowBottom)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        // Metal has warm tech-oriented glows
                        RadialGradient(
                            colors: [Color.orange.opacity(theme.windowAccentGlow * 0.80), Color.clear],
                            center: .topLeading, startRadius: 30, endRadius: 480
                        )
                        RadialGradient(
                            colors: [Color.purple.opacity(theme.windowAccentGlow * 0.60), Color.clear],
                            center: .bottomTrailing, startRadius: 20, endRadius: 400
                        )
                        RadialGradient(
                            colors: [Color.pink.opacity(theme.windowAccentGlow * 0.50), Color.clear],
                            center: .bottomLeading, startRadius: 15, endRadius: 320
                        )
                    }
                }
            }
            .overlay(alignment: .top) {
                if theme.windowTopBarHighlight > 0 {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(theme.windowTopBarHighlight),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 48)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct ThemedBottomBarModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.appAppearance) private var appearance

    func body(content: Content) -> some View {
        Group {
            if appearance == .liquidGlass {
                // Fully transparent — the window's behindWindow frosted glass shows through.
                // Adding only a hairline top separator to visually anchor the bar,
                // matching how RememberMyWindows separates its content regions.
                content
                    .overlay(alignment: .top) {
                        Color.white.opacity(0.12)
                            .frame(height: 0.5)
                            .allowsHitTesting(false)
                    }
            } else if appearance.isModernDesign {
                content
                    .background {
                        ZStack {
                            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                .opacity(theme.bottomBarMaterialOpacity)
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(theme.bottomBarGradientTop),
                                    Color.white.opacity(theme.bottomBarGradientBottom)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }
                        .clipShape(Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                        }
                        .shadow(color: Color.black.opacity(0.14), radius: 16, y: 8)
                        .allowsHitTesting(false)
                    }
                    .clipShape(Capsule(style: .continuous))
            } else {
                content
                    .background {
                        ZStack {
                            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                .opacity(theme.bottomBarMaterialOpacity)
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(theme.bottomBarGradientTop),
                                    Color.white.opacity(theme.bottomBarGradientBottom)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .allowsHitTesting(false)
                    }
            }
        }
    }
}


private struct ThemedTitleBarModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background {
                if theme.titleBarGradientTop > 0 {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(theme.titleBarGradientTop),
                            Color.white.opacity(theme.titleBarGradientBottom)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct ThemedTabBarBackgroundModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.modifier(
            ThemedSurfaceModifier(
                cornerRadius: theme.tabBarCornerRadius,
                material: theme.tabBarMaterial,
                tintOpacity: theme.tabBarTintOpacity,
                materialOpacity: theme.cardMaterialOpacity,
                borderOpacity: theme.cardBorderOpacity,
                shadowOpacity: theme.cardShadowOpacity * 0.75,
                highlightTop: theme.surfaceHighlightTop
            )
        )
    }
}
