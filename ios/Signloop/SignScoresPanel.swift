import SwiftUI

/// Debug-only UI in the sense of purpose, not fabricated debug output.
/// All rows come from the same real inference that drives the best guess.
struct SignScoresPanel: View {
    let scores: [BasicSignScore]
    @Binding var isPresented: Bool
    @Binding var showAll: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var ranked: [BasicSignScore] { BasicSignScore.ranked(scores) }
    private var visible: [BasicSignScore] { showAll ? ranked : Array(ranked.prefix(3)) }
    private var leader: String? { ranked.first(where: { $0.measuredDistance != nil })?.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Closest matches").font(.subheadline.bold())
                    Text("Distance ↓ · not probability").font(.caption2)
                        .accessibilityIdentifier("scores-disclaimer")
                }
                Spacer(minLength: 4)
                Button(showAll ? "Top 3" : "All \(scores.count)") { showAll.toggle() }
                    .font(.caption.bold()).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(showAll ? "Show top three matches" : "Show all candidates")
                    .accessibilityIdentifier("score-list-mode")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Hide sign scores").accessibilityIdentifier("hide-sign-scores")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                         count: !showAll || dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(visible) { score in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(BasicLiveRecognition.display(score.label))
                                    .fontWeight(score.label == leader ? .bold : .regular)
                                Spacer(minLength: 0)
                                Text(score.distanceText)
                                    .monospacedDigit()
                            }.font(.caption)
                            if score.label == leader {
                                Text("Closest · not confirmed").font(.caption2)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(BasicLiveRecognition.display(score.label))
                        .accessibilityValue(score.measuredDistance.map { String(format: "Distance %.3f, lower is closer, not probability", $0) }
                            ?? "No current score")
                        .accessibilityIdentifier("score-\(score.label)")
                    }
                }.padding(.bottom, 4)
            }.accessibilityIdentifier("sign-scores-list")
            Text("Lower is closer · — means insufficient tracking")
                .font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 4)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sign-scores-panel")
    }
}
