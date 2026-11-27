import SwiftUI

enum NativeTheme {
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.65, green: 0.80, blue: 0.94, alpha: 1)
        : UIColor(red: 0.18, green: 0.34, blue: 0.49, alpha: 1) })
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.08, green: 0.15, blue: 0.23, alpha: 1) : .white })
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.08, green: 0.12, blue: 0.17, alpha: 1)
        : UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1) })
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.12, green: 0.18, blue: 0.25, alpha: 1) : .white })
    static let secondaryText = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.71, green: 0.77, blue: 0.84, alpha: 1)
        : UIColor(red: 0.32, green: 0.39, blue: 0.47, alpha: 1) })
    static let inputBackground = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.09, green: 0.14, blue: 0.20, alpha: 1)
        : UIColor(red: 0.95, green: 0.97, blue: 0.98, alpha: 1) })
    static let inputError = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.62, blue: 0.60, alpha: 1)
        : UIColor(red: 0.67, green: 0.17, blue: 0.20, alpha: 1) })
    static let display = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let line = Color(UIColor.separator).opacity(0.35)

    static func inputPrompt(_ label: String) -> Text {
        Text(label).foregroundColor(secondaryText)
    }
}

struct NativeFormField<Input: View>: View {
    let title: String
    var hint: String? = nil
    var error: String? = nil
    @ViewBuilder var input: () -> Input
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? .primary : .secondary)
                .accessibilityHidden(true)
            input()
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(enabled ? .primary : .secondary)
                .tint(NativeTheme.accent)
                .accessibilityLabel(title)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background {
                    Rectangle().fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { if enabled { focused = true } }
                        .accessibilityHidden(true)
                }
                .nativeInputSurface(focused: focused, invalid: error != nil)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(NativeTheme.inputError)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(NativeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NativeInputSurface: ViewModifier {
    var focused: Bool
    var invalid: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    private var border: Color {
        if invalid { return NativeTheme.inputError }
        if focused && enabled { return NativeTheme.accent }
        return NativeTheme.secondaryText.opacity(contrast == .increased ? 1 : 0.72)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content
            .background(NativeTheme.inputBackground.opacity(enabled ? 1 : 0.5), in: shape)
            .overlay {
                shape.strokeBorder(border, lineWidth: focused && enabled ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func nativeInputSurface(focused: Bool, invalid: Bool = false) -> some View {
        modifier(NativeInputSurface(focused: focused, invalid: invalid))
    }
}

struct NativeActionStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled

    private var foreground: Color {
        switch kind {
        case .primary: NativeTheme.onAccent
        case .destructive: .red
        case .secondary, .quiet: NativeTheme.accent
        }
    }
    private var background: Color {
        switch kind {
        case .primary: NativeTheme.accent
        case .secondary: NativeTheme.accent.opacity(0.09)
        case .destructive: .red.opacity(0.08)
        case .quiet: .clear
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.subheadline : .body).weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(configuration.role == .destructive ? Color.red : foreground)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, 6)
            .frame(minHeight: compact ? 44 : 48)
            .background(configuration.role == .destructive ? Color.red.opacity(0.08) : background, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(NativeTheme.accent.opacity(0.13), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
    }
}

struct NativeSettingsLabel: View {
    let title: String
    let symbol: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(NativeTheme.accent).frame(width: 38, height: 38)
                .background(NativeTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
    }
}

struct NativeFilterOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? NativeTheme.accent : Color.secondary.opacity(0.4))
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.borderless).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
