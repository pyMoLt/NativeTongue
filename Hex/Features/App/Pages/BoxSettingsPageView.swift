import ComposableArchitecture
import HexCore
import SwiftUI

/// „Diktierbox“ settings (plan 5.10): default per mode, font, size, format.
struct BoxSettingsPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    FlowPage("Dictation Box", subtitle: "Collect and correct dictations, insert only with ✓", symbol: "text.below.photo") {
      FlowGroup("When does the box open?", footer: "The box opens when you press the dictation key. Further dictations are appended; selected text is replaced by the next dictation. Return and Esc never confirm or discard – only ✓ and ✕.") {
        toggle("In Literal mode", \.dictationBoxEnabledLiteral, "Default: on – for long or demanding texts.")
        toggle("In Normal mode", \.dictationBoxEnabledNormal, "Default: off – text is inserted directly.")
      }

      FlowGroup("Text") {
        Picker("Font", selection: Binding(
          get: { settings.boxFontName },
          set: { value in store.$hexSettings.withLock { $0.boxFontName = value } }
        )) {
          ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
            Text(choice.title).tag(choice.name)
          }
        }
        .flowRow("Font")
        FlowRow("Size") {
          HStack(spacing: 10) {
            Slider(
              value: Binding(get: { settings.boxFontSize }, set: { value in store.$hexSettings.withLock { $0.boxFontSize = value.rounded() } }),
              in: 11 ... 28,
              step: 1
            )
            .frame(width: 200)
            Text("\(Int(settings.boxFontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
          }
        }
        Picker("Insert as", selection: Binding(
          get: { settings.boxOutputFormat },
          set: { value in store.$hexSettings.withLock { $0.boxOutputFormat = value } }
        )) {
          Text("Rich Text (Word, Pages, Mail)").tag(OutputFormat.richText)
          Text("Markdown").tag(OutputFormat.markdown)
          Text("Plain text").tag(OutputFormat.plainText)
        }
        .flowRow("Insert as")
        FlowBlock {
          Text("The quick brown fox jumps over the lazy dog.")
            .font(Font(BoxTextStyle.baseFont(name: settings.boxFontName, size: settings.boxFontSize)))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      FlowGroup("Window") {
        FlowRow("Box position", caption: "Moves the box back to its default place.") {
          Button("Reset") {
            NotificationCenter.default.post(name: .resetDictationBoxPosition, object: nil)
          }
          .buttonStyle(.flow)
        }
      }
    }
  }

  private func toggle(_ title: String, _ keyPath: WritableKeyPath<HexSettings, Bool>, _ caption: String) -> some View {
    Toggle(isOn: Binding(
      get: { settings[keyPath: keyPath] },
      set: { value in store.$hexSettings.withLock { $0[keyPath: keyPath] = value } }
    )) {
      FlowLabel(title, caption: caption)
    }
  }
}

extension Notification.Name {
  static let resetDictationBoxPosition = Notification.Name("LocalASR.resetDictationBoxPosition")
}
