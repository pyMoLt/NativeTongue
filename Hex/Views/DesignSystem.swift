import HexCore
import SwiftUI

/// Shared constants; the components of the "Flow" design (2.6) live in
/// `Views/Flow/`.
enum LocalASRDesign {
  static let cornerRadius: CGFloat = FlowMetrics.panelRadius
  static let pagePadding: CGFloat = FlowMetrics.pagePadding
}

struct Badge: View {
  enum Style { case positive, caution, neutral, accent }
  let text: String
  var systemImage: String?
  var style: Style = .neutral
  @Environment(\.flowTheme) private var theme

  private var tint: Color {
    switch style {
    case .positive: .green
    case .caution: .orange
    case .neutral: .secondary
    case .accent: theme.accent
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text)
    }
    .flowFont(.caption, weight: .medium)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .foregroundStyle(style == .neutral ? Color.secondary : tint)
    .background(tint.opacity(style == .neutral ? 0.12 : 0.15), in: Capsule())
  }
}

/// Lays out children left to right and wraps whole items onto new lines
/// (badges never break inside a word).
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
      if needed > width, !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
      rows[rows.count - 1] = row
    }
    return rows
  }
}

/// Large Normal / Literal / Streaming switch: three glass pills that flow
/// into each other when the selection changes.
struct ModeSwitch: View {
  let mode: DictationMode
  let onChange: (DictationMode) -> Void
  @Namespace private var namespace
  @Environment(\.flowTheme) private var theme

  var body: some View {
    GlassEffectContainer(spacing: 10) {
      HStack(spacing: 8) {
        segment(.normal, title: "Normal", subtitle: "Natural text for chats and AI agents", symbol: "waveform")
        segment(.literal, title: "Literal", subtitle: "Spoken punctuation, precise texts", symbol: "paragraphsign")
        segment(.streaming, title: "Streaming", subtitle: "Words appear while you speak", symbol: "dot.radiowaves.left.and.right")
      }
    }
    .animation(theme.animation(), value: mode)
  }

  private func segment(_ value: DictationMode, title: String, subtitle: String, symbol: String) -> some View {
    let selected = mode == value
    return Button {
      onChange(value)
    } label: {
      HStack(spacing: 11) {
        Image(systemName: symbol)
          .flowFont(size: 15, weight: .semibold)
          .foregroundStyle(selected ? Color.white : theme.accent)
          .frame(width: 32 * theme.textScale, height: 32 * theme.textScale)
          .background(selected ? AnyShapeStyle(theme.accent.gradient) : AnyShapeStyle(theme.accent.opacity(0.14)), in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text(title).flowFont(.headline, design: .rounded)
          Text(subtitle).flowFont(.caption).foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 66)
      .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    .buttonStyle(.plain)
    .flowSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true, highlighted: selected)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel("\(title) mode")
  }
}

extension LocalASRLiteralRating {
  var badge: Badge {
    switch self {
    case .reliable: Badge(text: "Literal: reliable", systemImage: "checkmark.seal.fill", style: .positive)
    case .limited: Badge(text: "Literal: limited", systemImage: "exclamationmark.triangle.fill", style: .caution)
    case .unverified: Badge(text: "Literal: unverified", systemImage: "questionmark.circle", style: .neutral)
    case .unsuitable: Badge(text: "Not for Literal", systemImage: "xmark.circle", style: .caution)
    }
  }
}

extension LocalASRStreamingSupport {
  var badge: Badge {
    switch self {
    case .native: Badge(text: "Streaming: live", systemImage: "dot.radiowaves.left.and.right", style: .positive)
    case .emulated: Badge(text: "Streaming: after pauses", systemImage: "pause.circle", style: .neutral)
    case .none: Badge(text: "No streaming", systemImage: "minus.circle", style: .neutral)
    }
  }
}

extension LocalASRModelGroup {
  var title: String {
    switch self {
    case .recommended: "Recommended"
    case .general: "General"
    case .medical: "Medical"
    case .experimental: "Experimental"
    }
  }
}

/// Single source for the product name (Info.plist `CFBundleDisplayName`), so
/// a rename touches only Info.plist and the product name build setting.
enum AppBrand {
  static var name: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      .map { $0.replacingOccurrences(of: " Debug", with: "") } ?? "NativeTongue"
  }
}
