import ComposableArchitecture
import HexCore
import SwiftUI

/// „Diktierbox“ settings (plan 5.10): default per mode, font, size, format.
struct BoxSettingsPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    FlowPage("Dictation Box", subtitle: "Collect and correct dictations, insert only with ✓", symbol: "text.below.photo") {
      FlowGroup("Use the box", footer: "Further dictations are appended; selected text is replaced by the next dictation. Return and Esc never confirm or discard – only ✓ and ✕.") {
        toggle("In Literal mode", \.dictationBoxEnabledLiteral, "Default: on – for long or demanding texts.")
        toggle("In Normal mode", \.dictationBoxEnabledNormal, "Default: off – text is inserted directly.")
      }

      FlowGroup("When does the box open?") {
        FlowSegmented(selection: Binding(
          get: { settings.boxOpenTiming },
          set: { value in store.$hexSettings.withLock { $0.boxOpenTiming = value } }
        ), options: [
          FlowOption(DictationBoxOpenTiming.afterFirstDictation, "After the first dictation"),
          FlowOption(.immediately, "When recording starts"),
        ])
        .flowRow("Opens", caption: settings.boxOpenTiming == .afterFirstDictation
          ? "Like Dragon: the box appears with the text of your first dictation. A cancelled or empty dictation opens nothing."
          : "The box appears as soon as you press the dictation key. If nothing is dictated, it closes again after the wait below.")
        if settings.boxOpenTiming == .immediately {
          Stepper("", value: Binding(
            get: { settings.boxAutoCloseSeconds },
            set: { value in store.$hexSettings.withLock { $0.boxAutoCloseSeconds = value } }
          ), in: 1 ... 10, step: 1)
          .flowRow("Close an empty box after \(Int(settings.boxAutoCloseSeconds)) s", caption: "Only if it never held text and no new dictation starts. A box you cleared by hand stays open.")
        }
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

      FlowGroup("Window", footer: "Style, size, transparency and colours: Appearance → Dictation Box.") {
        FlowRow("Position and size", caption: "The box opens where and as large as you left it. Reset moves it back to the bottom centre in the default size of its style.") {
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
