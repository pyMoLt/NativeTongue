import HexCore
import SwiftUI

// MARK: - Page

/// The one page layout: header, fixed content width, same spacing everywhere.
struct FlowPage<Content: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  var accessory: AnyView?
  @ViewBuilder var content: Content

  init(_ title: String, subtitle: String, symbol: String, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.accessory = accessory
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: FlowMetrics.groupSpacing) {
        PageHeader(title: title, subtitle: subtitle, symbol: symbol, accessory: accessory)
        content
      }
      .frame(maxWidth: FlowMetrics.contentWidth, alignment: .leading)
      .padding(.horizontal, FlowMetrics.pagePadding)
      .padding(.top, 30)
      .padding(.bottom, FlowMetrics.pagePadding)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
  }
}

/// Page title with a colour orb in the accent gradient.
struct PageHeader: View {
  let title: String
  let subtitle: String
  let symbol: String
  var accessory: AnyView?
  @Environment(\.flowTheme) private var theme

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      FlowOrb(symbol: symbol, size: 52)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).flowFont(size: 26, weight: .bold, design: .rounded)
        Text(subtitle).flowFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if let accessory { accessory }
    }
    .padding(.bottom, 2)
  }
}

/// Rounded symbol tile in the accent gradient (page headers, onboarding, popover).
struct FlowOrb: View {
  let symbol: String
  var size: CGFloat = 52
  @Environment(\.flowTheme) private var theme

  var body: some View {
    let size = size * theme.textScale
    return Image(systemName: symbol)
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        LinearGradient(colors: [theme.accent, theme.companion], startPoint: .topLeading, endPoint: .bottomTrailing),
        in: .rect(cornerRadius: size * 0.3, style: .continuous)
      )
      .shadow(color: theme.accent.opacity(0.30), radius: size * 0.22, y: size * 0.1)
      .accessibilityHidden(true)
  }
}

// MARK: - Groups and rows

/// A group of pills with a small heading and optional explanation below.
/// No frame: the pills themselves are the elements.
struct FlowGroup<Content: View>: View {
  var title: String?
  var footer: String?
  @ViewBuilder var content: Content

  init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(title)
          .flowFont(size: 13, weight: .semibold, design: .rounded)
          .foregroundStyle(.secondary)
          .padding(.leading, FlowMetrics.rowInsets.leading)
          .accessibilityAddTraits(.isHeader)
      }
      GlassEffectContainer(spacing: FlowMetrics.pillSpacing) {
        VStack(alignment: .leading, spacing: FlowMetrics.pillSpacing) {
          content
        }
      }
      .toggleStyle(FlowToggleStyle())
      if let footer, !footer.isEmpty {
        FlowNote(footer)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One setting: text (and optional explanation) left, control right, on a pill.
struct FlowRow<Control: View>: View {
  let title: String
  var caption: String?
  var systemImage: String?
  @ViewBuilder var control: Control

  init(_ title: String, caption: String? = nil, systemImage: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.caption = caption
    self.systemImage = systemImage
    self.control = control()
  }

  var body: some View {
    FlowRowLayout(title: title, caption: caption, systemImage: systemImage) {
      control
        .labelsHidden()
        .fixedSize()
    }
  }
}

/// Row container used by `FlowRow` and the toggle style.
struct FlowRowLayout<Trailing: View>: View {
  let title: String
  var caption: String?
  var systemImage: String?
  @ViewBuilder var trailing: Trailing
  @Environment(\.flowTheme) private var theme

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      if let systemImage {
        Image(systemName: systemImage)
          .flowFont(size: 13, weight: .semibold)
          .foregroundStyle(theme.accent)
          .frame(width: 22)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fixedSize(horizontal: false, vertical: true)
        if let caption, !caption.isEmpty {
          Text(caption).flowFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
        .layoutPriority(1)
    }
    .padding(FlowMetrics.rowInsets)
    .frame(minHeight: FlowMetrics.rowMinHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .flowPill()
    .accessibilityElement(children: .contain)
  }
}

extension View {
  /// Puts a picker, stepper, slider or button into a Flow row.
  func flowRow(_ title: String, caption: String? = nil, systemImage: String? = nil) -> some View {
    FlowRow(title, caption: caption, systemImage: systemImage) { self }
  }
}

/// Content that is not a single setting (status, previews, lists) on a pill
/// surface of the same width.
struct FlowBlock<Content: View>: View {
  var padding: CGFloat = 16
  @ViewBuilder var content: Content

  init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .flowPanel()
  }
}

/// Toggle as a Flow row: label left, switch right.
struct FlowToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 14) {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle("", isOn: configuration.$isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
    .padding(FlowMetrics.rowInsets)
    .frame(minHeight: FlowMetrics.rowMinHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .flowPill()
  }
}

/// Toggle label with an explanation line.
struct FlowLabel: View {
  let title: String
  var caption: String?

  init(_ title: String, caption: String? = nil) {
    self.title = title
    self.caption = caption
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      if let caption, !caption.isEmpty {
        Text(caption).flowFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Explanation text under a group or row.
struct FlowNote: View {
  let text: String
  var systemImage: String?
  var tone: Tone = .secondary

  enum Tone { case secondary, warning }

  init(_ text: String, systemImage: String? = nil, tone: Tone = .secondary) {
    self.text = text
    self.systemImage = systemImage
    self.tone = tone
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
    .flowFont(.caption)
    .foregroundStyle(tone == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
    .padding(.horizontal, FlowMetrics.rowInsets.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Segments

struct FlowOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var systemImage: String?
  var id: Value { value }

  init(_ value: Value, _ title: String, systemImage: String? = nil) {
    self.value = value
    self.title = title
    self.systemImage = systemImage
  }
}

/// Pill segments with a selection pill that glides between the options.
struct FlowSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [FlowOption<Value>]
  var compact = false
  @Namespace private var namespace
  @Environment(\.flowTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options) { option in
        let selected = option.value == selection
        Button {
          withAnimation(theme.animation()) { selection = option.value }
        } label: {
          HStack(spacing: 5) {
            if let symbol = option.systemImage { Image(systemName: symbol) }
            Text(option.title).lineLimit(1)
          }
          .flowFont(compact ? .caption : .callout, weight: selected ? .semibold : .regular)
          .padding(.horizontal, compact ? 9 : 13)
          .padding(.vertical, compact ? 4 : 6)
          .foregroundStyle(selected ? Color.white : Color.primary)
          .background {
            if selected {
              Capsule()
                .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                .matchedGeometryEffect(id: "selection", in: namespace)
            }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .flowSurface(Capsule())
    .opacity(isEnabled ? 1 : 0.5)
  }
}

// MARK: - Buttons and fields

struct FlowButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, destructive, quiet }
  var kind: Kind = .secondary
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    FlowButtonBody(configuration: configuration, kind: kind, compact: compact)
  }
}

private struct FlowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: FlowButtonStyle.Kind
  let compact: Bool
  @Environment(\.flowTheme) private var theme
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let label = configuration.label
      .flowFont(compact ? .caption : .callout, weight: .medium)
      .lineLimit(1)
      .padding(.horizontal, compact ? 10 : 14)
      .padding(.vertical, compact ? 4 : 6)
    Group {
      switch kind {
      case .primary:
        label
          .foregroundStyle(.white)
          .background(LinearGradient(colors: [theme.accent, theme.companion], startPoint: .leading, endPoint: .trailing), in: Capsule())
      case .secondary:
        label.foregroundStyle(.primary).flowSurface(Capsule(), interactive: true)
      case .destructive:
        label.foregroundStyle(.red).flowSurface(Capsule(), interactive: true)
      case .quiet:
        label.foregroundStyle(.secondary).contentShape(Capsule())
      }
    }
    .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    .scaleEffect(configuration.isPressed ? 0.97 : 1)
    .animation(theme.animation(.snappy(duration: 0.15)), value: configuration.isPressed)
  }
}

extension ButtonStyle where Self == FlowButtonStyle {
  static var flow: FlowButtonStyle { FlowButtonStyle() }
  static var flowPrimary: FlowButtonStyle { FlowButtonStyle(kind: .primary) }
  static var flowDestructive: FlowButtonStyle { FlowButtonStyle(kind: .destructive) }
  static var flowQuiet: FlowButtonStyle { FlowButtonStyle(kind: .quiet) }
  static var flowCompact: FlowButtonStyle { FlowButtonStyle(compact: true) }
}

extension View {
  /// Text field on a pill.
  func flowField() -> some View {
    self
      .textFieldStyle(.plain)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .flowSurface(Capsule())
  }
}

// MARK: - Empty state

struct FlowEmptyState: View {
  let symbol: String
  let title: String
  var message: String?

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .flowFont(size: 28, weight: .light)
        .foregroundStyle(.secondary)
      Text(title).flowFont(.headline)
      if let message {
        Text(message).flowFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(28)
  }
}
