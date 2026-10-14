import HexCore
import Inject
import Sauce
import SwiftUI

/// The dictation key as pill-shaped key caps (Flow design).
struct HotKeyView: View {
  @ObserveInjection var inject
  var modifiers: Modifiers
  var key: Key?
  var isActive: Bool
  @Environment(\.flowTheme) private var theme

  var body: some View {
    HStack(spacing: 6) {
      if modifiers.isHyperkey {
        KeyView(text: "✦")
          .transition(.blurReplace)
      } else {
        ForEach(modifiers.sorted) { modifier in
          KeyView(text: modifier.stringValue)
            .transition(.blurReplace)
        }
      }
      if let key {
        KeyView(text: key.toString)
      }
      if isActive, key == nil, modifiers.isEmpty {
        Text("Press a key combination")
          .foregroundStyle(.secondary)
          .transition(.blurReplace)
      } else if modifiers.isEmpty, key == nil {
        Text("Not set").foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(theme.accent.opacity(isActive ? 0.16 : 0), in: Capsule())
    .overlay(Capsule().strokeBorder(theme.accent.opacity(isActive ? 0.45 : 0), lineWidth: 1))
    .animation(theme.animation(.bouncy(duration: 0.3)), value: key)
    .animation(theme.animation(.bouncy(duration: 0.3)), value: modifiers)
    .animation(theme.animation(.bouncy(duration: 0.3)), value: isActive)
    .enableInjection()
  }
}

struct KeyView: View {
  @ObserveInjection var inject
  var text: String
  @Environment(\.flowTheme) private var theme

  var body: some View {
    Text(text)
      .flowFont(size: 17, weight: .semibold, design: .rounded)
      .foregroundStyle(theme.accent)
      .frame(minWidth: 38 * theme.textScale, minHeight: 32 * theme.textScale)
      .padding(.horizontal, 4)
      .background(theme.accent.opacity(0.14), in: Capsule())
      .enableInjection()
  }
}

#Preview {
  HotKeyView(
    modifiers: .init(modifiers: [.command, .shift]),
    key: .a,
    isActive: true
  )
}
