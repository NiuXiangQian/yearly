import SwiftUI

enum NativeTheme {
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.64, green: 0.79, blue: 0.69, alpha: 1)
        : UIColor(red: 0.20, green: 0.36, blue: 0.29, alpha: 1) })
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.08, green: 0.16, blue: 0.12, alpha: 1) : .white })
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)
        : UIColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1) })
    static let line = Color(UIColor.separator).opacity(0.35)
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
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .foregroundStyle(configuration.role == .destructive ? Color.red : foreground)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(minHeight: compact ? 40 : 48)
            .background(configuration.role == .destructive ? Color.red.opacity(0.08) : background, in: RoundedRectangle(cornerRadius: compact ? 20 : 14, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: compact ? 20 : 14, style: .continuous)
                        .strokeBorder(NativeTheme.accent.opacity(0.13), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: compact ? 20 : 14))
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
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            }.frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
