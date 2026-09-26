import HexCore
import SwiftUI

/// Shared building blocks of the V2 interface (plan 5.10): calm cards on the
/// window background, Liquid Glass only on floating layers and controls.
enum LocalASRDesign {
  static let cornerRadius: CGFloat = 14
  static let pagePadding: CGFloat = 24
  static let mint = Color.accentColor
}

struct PageHeader: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.tint)
        .frame(width: 44, height: 44)
        .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .rect(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title2.weight(.semibold))
        Text(subtitle).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
}

struct Card<Content: View>: View {
  var title: String?
  var systemImage: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        Label {
          Text(title).font(.headline)
        } icon: {
          if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
        }
      }
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: LocalASRDesign.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: LocalASRDesign.cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.07))
    )
  }
}

struct Badge: View {
  enum Style { case positive, caution, neutral, accent }
  let text: String
  var systemImage: String?
  var style: Style = .neutral

  private var tint: Color {
    switch style {
    case .positive: .green
    case .caution: .orange
    case .neutral: .secondary
    case .accent: .accentColor
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .foregroundStyle(style == .neutral ? Color.secondary : tint)
    .background(tint.opacity(style == .neutral ? 0.12 : 0.15), in: Capsule())
  }
}

/// Large Normal / Literal switch (segmented glass capsules).
struct ModeSwitch: View {
  let mode: DictationMode
  let onChange: (DictationMode) -> Void
  @Namespace private var namespace

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 6) {
        segment(.normal, title: "Normal", subtitle: "natural text for chats & AI agents", symbol: "waveform")
        segment(.literal, title: "Literal", subtitle: "precise dictation for demanding texts", symbol: "paragraphsign")
      }
    }
    .animation(.smooth(duration: 0.25), value: mode)
  }

  private func segment(_ value: DictationMode, title: String, subtitle: String, symbol: String) -> some View {
    let selected = mode == value
    return Button {
      onChange(value)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.title3.weight(.semibold))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 12))
    .glassEffectID(value == .normal ? "normal" : "literal", in: namespace)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityLabel("\(title)-Modus")
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

extension Text {
  /// Caption font with secondary color for helper text in settings.
  func settingsCaption() -> some View {
    self.font(.caption).foregroundStyle(.secondary)
  }
}

/// Single source for the product name (Info.plist `CFBundleDisplayName`), so
/// a rename touches only Info.plist and the product name build setting.
enum AppBrand {
  static var name: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      .map { $0.replacingOccurrences(of: " Debug", with: "") } ?? "Local ASR"
  }
}
