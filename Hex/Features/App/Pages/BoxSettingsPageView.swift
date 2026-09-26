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
        PageHeader(title: "Diktierbox", subtitle: "Diktate sammeln, korrigieren und erst mit ✓ einfügen", symbol: "text.below.photo")
        Card(title: "Wann öffnet die Box?", systemImage: "rectangle.on.rectangle") {
          toggle("Im Literal-Modus", \.dictationBoxEnabledLiteral, "Standard: an – für Befunde und längere Texte.")
          toggle("Im Normal-Modus", \.dictationBoxEnabledNormal, "Standard: aus – Text wird direkt eingefügt.")
          Text("Die Box öffnet sich beim Drücken der Diktat-Taste. Weitere Diktate hängen an; markierter Text wird durch das nächste Diktat ersetzt. Eingabe und Esc lösen nichts aus – nur ✓ und ✕.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Card(title: "Darstellung", systemImage: "textformat") {
          Picker("Schrift", selection: Binding(
            get: { settings.boxFontName },
            set: { value in store.$hexSettings.withLock { $0.boxFontName = value } }
          )) {
            ForEach(BoxTextStyle.fontChoices, id: \.name) { choice in
              Text(choice.title).tag(choice.name)
            }
          }
          HStack {
            Text("Größe")
            Slider(
              value: Binding(get: { settings.boxFontSize }, set: { value in store.$hexSettings.withLock { $0.boxFontSize = value.rounded() } }),
              in: 11 ... 28,
              step: 1
            )
            Text("\(Int(settings.boxFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
          }
          Picker("Einfügen als", selection: Binding(
            get: { settings.boxOutputFormat },
            set: { value in store.$hexSettings.withLock { $0.boxOutputFormat = value } }
          )) {
            Text("Rich Text (Word, Pages, Mail)").tag(OutputFormat.richText)
            Text("Markdown").tag(OutputFormat.markdown)
            Text("Klartext").tag(OutputFormat.plainText)
          }
          Text("Befund unauffällig. Kein Hinweis auf Thrombose.")
            .font(Font(BoxTextStyle.baseFont(name: settings.boxFontName, size: settings.boxFontSize)))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          Button("Position der Box zurücksetzen") {
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
