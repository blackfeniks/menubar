import AppKit
import SwiftUI

@MainActor @Observable
final class BarChoices {
	nonisolated static let space = "bar.choices"

	@ObservationIgnored var onChange: ((Bool) -> Void)?
	@ObservationIgnored var onHover: ((BarWheel, Int?) -> Void)?

	private(set) var open: AnyHashable?
	private(set) var picker: BarWheel?
	private(set) var pickerWidth: CGFloat = 0
	var frames: [AnyHashable: CGRect] = [:]

	func show(_ id: AnyHashable, titles: [String], hints: [String?] = [], checked: Int?, panelWidth: CGFloat, pick: @escaping (Int) -> Void) {
		guard !titles.isEmpty else { return }
		let rows = titles.enumerated().map { i, title in
			BarWheelRow(title: title, hint: hints.indices.contains(i) ? hints[i] : nil) { [weak self] in
				pick(i)
				self?.dismiss()
			}
		}
		let font = NSFont.systemFont(ofSize: Bar.text)
		let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
		pickerWidth = min(panelWidth - 2 * 10, max(120, ceil(widest) + 14 + 40))
		let list = BarWheel(rows: rows, visible: 5, checked: checked, picker: true)
		list.onHover = { [weak self, weak list] row in
			guard let self, let list else { return }
			self.onHover?(list, row)
		}
		picker = list
		open = id
		onChange?(true)
	}

	func dismiss() {
		guard open != nil else { return }
		open = nil
		picker = nil
		onChange?(false)
	}
}

struct BarChoiceRow: View {
	let title: String
	let value: String
	let id: AnyHashable
	let choices: BarChoices
	var disabled = false
	let open: () -> Void

	var body: some View {
		BarRow(title: title) {
			Button(action: open) {
				HStack(spacing: 5) {
					Text(value).lineLimit(1).truncationMode(.tail)
					Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
				}
				.foregroundStyle(Bar.t2)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.disabled(disabled)
		}
		.opacity(disabled ? 0.45 : 1)
		.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(BarChoices.space)) }) { choices.frames[id] = $0 }
	}
}

private struct BarChoiceLayer: View {
	let choices: BarChoices
	let width: CGFloat

	var body: some View {
		if let id = choices.open, let list = choices.picker {
			GeometryReader { panel in
				let cardWidth = choices.pickerWidth
				let height = list.geometry.height + 8
				let row = choices.frames[id] ?? .zero
				let y = min(max(8, row.midY - height / 2), panel.size.height - height - 8)
				ZStack(alignment: .topLeading) {
					Color.white.opacity(0.001).onTapGesture { choices.dismiss() }
					card(list, width: cardWidth, height: height)
						.offset(x: width - 10 - cardWidth, y: y)
				}
			}
			.transition(.barDevelop)
		}
	}

	private func card(_ list: BarWheel, width: CGFloat, height: CGFloat) -> some View {
		ZStack(alignment: .topLeading) {
			BarWheelRows(rows: list.rows, checked: list.checked, width: width,
			             style: BarWheelStyle(leading: 14, trailing: 18, bandInset: 4), model: list.model)
			BarWheelHost(control: list)
		}
		.frame(width: width, height: height - 8)
		.padding(.vertical, 4)
		.barGlass(corner: 13)
	}
}

extension View {
	func barChoices(_ choices: BarChoices, width: CGFloat) -> some View {
		overlay { BarChoiceLayer(choices: choices, width: width) }
			.coordinateSpace(.named(BarChoices.space))
	}
}

struct BarSegments<T: Hashable>: View {
	let options: [(value: T, title: String)]
	@Binding var selection: T
	var disabled = false
	@Namespace private var plate

	var body: some View {
		HStack(spacing: 2) {
			ForEach(options, id: \.value) { option in
				let chosen = option.value == selection
				Text(option.title)
					.font(.system(size: Bar.text, weight: chosen ? .medium : .regular))
					.foregroundStyle(chosen ? Bar.t1 : Bar.t2)
					.lineLimit(1)
					.fixedSize()
					.padding(.horizontal, 13)
					.frame(height: 24)
					.background {
						if chosen {
							RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.14))
								.matchedGeometryEffect(id: "plate", in: plate)
						}
					}
					.contentShape(Rectangle())
					.onTapGesture {
						guard !disabled, !chosen else { return }
						withAnimation(.snappy(duration: 0.22)) { selection = option.value }
					}
			}
		}
		.padding(2)
		.background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.055)))
		.opacity(disabled ? 0.45 : 1)
	}
}

struct BarButtonStyle: ButtonStyle {
	var prominent = false

	func makeBody(configuration: Configuration) -> some View {
		BarButtonBody(configuration: configuration, prominent: prominent)
	}

	private struct BarButtonBody: View {
		let configuration: Configuration
		let prominent: Bool
		@Environment(\.isEnabled) private var enabled

		var body: some View {
			configuration.label
				.font(.system(size: Bar.text, weight: .medium))
				.foregroundStyle(prominent ? Color.black.opacity(0.88) : Bar.t1)
				.lineLimit(1)
				.padding(.horizontal, 14)
				.frame(height: 26)
				.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(Color.white.opacity(prominent ? 0.92 : 0.1)))
				.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.32)
				.contentShape(Rectangle())
		}
	}
}
