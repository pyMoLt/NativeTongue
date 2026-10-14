import SwiftUI
import Inject
import MarkdownUI

struct ChangelogView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageHeader(title: "Changelog", subtitle: "What changed in each version", symbol: "list.bullet.rectangle")
                    .padding(.bottom, 6)

                if let changelogPath = Bundle.main.path(forResource: "changelog", ofType: "md"),
                    let changelogContent = try? String(
                        contentsOfFile: changelogPath, encoding: .utf8)
                {
                    Markdown(changelogContent)
                } else {
                    Text("Changelog could not be loaded.")
                        .foregroundColor(.red)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(FlowBackdrop())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .enableInjection()
    }
}
