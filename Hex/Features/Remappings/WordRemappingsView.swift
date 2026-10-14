import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct WordRemappingsView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@FocusState private var isScratchpadFocused: Bool

	var body: some View {
		FlowPage("Word Rules", subtitle: "Remove words and shape the final text of every dictation", symbol: "text.badge.minus") {
			previewSection
			removalsSection
			outputFormattingSection
		}
		.onDisappear {
			store.send(.setRemappingScratchpadFocused(false))
		}
		.enableInjection()
	}

	private var previewSection: some View {
		FlowGroup("Preview", footer: "Replacements of words live in Vocabulary (spelling + variants).") {
			HStack(alignment: .center, spacing: 10) {
				TextField("Type or speak a sample…", text: $store.remappingScratchpadText)
					.flowField()
					.focused($isScratchpadFocused)
					.onChange(of: isScratchpadFocused) { _, newValue in
						store.send(.setRemappingScratchpadFocused(newValue))
					}
				Image(systemName: "arrow.right")
					.foregroundStyle(.tertiary)
				Text(previewText.isEmpty ? "—" : previewText)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 14)
					.padding(.vertical, 7)
					.flowSurface(Capsule(), highlighted: true)
					.accessibilityLabel("Result")
			}
		}
	}

	private var removalsSection: some View {
		FlowGroup("Remove words") {
			Toggle(isOn: Binding(
				get: { store.hexSettings.wordRemovalsEnabled },
				set: { store.send(.setWordRemovalsEnabled($0)) }
			)) {
				FlowLabel("Remove matching words", caption: "Regular expressions, applied to every transcript.")
			}
			ForEach(store.hexSettings.wordRemovals) { removal in
				RemovalRow(removal: removalBinding(for: removal)) {
					store.send(.removeWordRemoval(removal.id))
				}
			}
			HStack {
				Spacer()
				Button {
					store.send(.addWordRemoval)
				} label: {
					Label("Add pattern", systemImage: "plus")
				}
				.buttonStyle(.flow)
			}
		}
	}

	private var outputFormattingSection: some View {
		FlowGroup("Output formatting") {
			Toggle(isOn: Binding(
				get: { store.hexSettings.lowercaseTranscripts },
				set: { store.send(.setLowercaseTranscripts($0)) }
			)) {
				FlowLabel("Lowercase output")
			}
			Toggle(isOn: Binding(
				get: { store.hexSettings.removePunctuation },
				set: { store.send(.setRemovePunctuation($0)) }
			)) {
				FlowLabel("Remove punctuation")
			}
		}
	}

	private func removalBinding(for removal: WordRemoval) -> Binding<WordRemoval> {
		return Binding(
			get: {
				store.hexSettings.wordRemovals.first { $0.id == removal.id } ?? removal
			},
			set: { store.send(.updateWordRemoval($0)) }
		)
	}

	private var previewText: String {
		var output = store.remappingScratchpadText
		if store.hexSettings.wordRemovalsEnabled {
			output = WordRemovalApplier.apply(output, removals: store.hexSettings.wordRemovals)
		}
		output = WordRemappingApplier.apply(output, remappings: store.hexSettings.wordRemappings)
		output = TranscriptFormattingApplier.apply(
			output,
			lowercase: store.hexSettings.lowercaseTranscripts,
			removePunctuation: store.hexSettings.removePunctuation
		)
		return output
	}
}

private struct RemovalRow: View {
	@Binding var removal: WordRemoval
	var onDelete: () -> Void

	var body: some View {
		HStack(spacing: 10) {
			Toggle("", isOn: $removal.isEnabled)
				.labelsHidden()
				.toggleStyle(.checkbox)
				.accessibilityLabel("Enable \(removal.pattern.isEmpty ? "removal" : removal.pattern)")
			TextField("Regex pattern", text: $removal.pattern)
				.textFieldStyle(.plain)
				.flowFont(.body, monospaced: true)
			Button(role: .destructive, action: onDelete) {
				Image(systemName: "trash")
			}
			.buttonStyle(.flowQuiet)
			.help("Delete removal")
		}
		.padding(FlowMetrics.rowInsets)
		.frame(minHeight: FlowMetrics.rowMinHeight)
		.flowPill()
	}
}
