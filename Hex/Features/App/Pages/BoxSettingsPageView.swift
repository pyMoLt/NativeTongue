import ComposableArchitecture
import HexCore
import SwiftUI

/// „Diktierbox“ settings (plan 5.10): default per mode, font, size, format.
struct BoxSettingsPageView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  private var settings: HexSettings { store.hexSettings }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: "Dictation Box", subtitle: "Collect and correct dictations, insert only with ✓", symbol: "text.below.photo")
        Card(title: "When does the box open?", systemImage: "rectangle.on.rectangle") {
          toggle("In Literal mode", \.dictationBoxEnabledLiteral, "Default: on – for long or demanding texts.")
          toggle("In Normal mode", \.dictationBoxEnabledNormal, "Default: off – text is inserted directly.")
          Text("The box opens when you press the dictation key. Further dictations are appended; selected text is replaced by the next dictation. Return and Esc never confirm or discard – only ✓ and ✕.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Card(title: "Appearance", systemImage: "textformat") {
          Picker("Font", selection: Binding(
            get: { settings.boxFontName },
            set: { value in store.$hexSettings.withLock { $0.boxFontName = value } }
          )) {
            ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
              Text(choice.title).tag(choice.name)
            }
          }
          HStack {
            Text("Size")
            Slider(
              value: Binding(get: { settings.boxFontSize }, set: { value in store.$hexSettings.withLock { $0.boxFontSize = value.rounded() } }),
              in: 11 ... 28,
              step: 1
            )
            Text("\(Int(settings.boxFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
          }
          Picker("Insert as", selection: Binding(
            get: { settings.boxOutputFormat },
            set: { value in store.$hexSettings.withLock { $0.boxOutputFormat = value } }
          )) {
            Text("Rich Text (Word, Pages, Mail)").tag(OutputFormat.richText)
            Text("Markdown").tag(OutputFormat.markdown)
            Text("Plain text").tag(OutputFormat.plainText)
          }
          Text("The quick brown fox jumps over the lazy dog.")
            .font(Font(BoxTextStyle.baseFont(name: settings.boxFontName, size: settings.boxFontSize)))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          Button("Reset box position") {
            NotificationCenter.default.post(name: .resetDictationBoxPosition, object: nil)
          }
          .buttonStyle(.glass)
        }
      }
      .padding(LocalASRDesign.pagePadding)
    }
  }

  private func toggle(_ title: String, _ keyPath: WritableKeyPath<HexSettings, Bool>, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Toggle(title, isOn: Binding(
        get: { settings[keyPath: keyPath] },
        set: { value in store.$hexSettings.withLock { $0[keyPath: keyPath] = value } }
      ))
      .toggleStyle(.switch)
      Text(caption).font(.caption).foregroundStyle(.secondary)
    }
  }
}

extension Notification.Name {
  static let resetDictationBoxPosition = Notification.Name("LocalASR.resetDictationBoxPosition")
}
