import SwiftUI

/// Debug-only UI in the sense of purpose, not fabricated debug output.
/// All rows come from the same real inference that drives Possible sign/Unknown.
struct SignScoresPanel: View {
    let scores: [BasicSignScore]
    @Binding var isPresented: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var leader: String? {
        scores.filter { $0.distance != nil }.min { $0.distance! < $1.distance! }?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All sign scores").font(.subheadline.bold())
                    Text("Similarity %, not probability").font(.caption2)
                        .accessibilityIdentifier("scores-disclaimer")
                }
                Spacer(minLength: 4)
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Hide sign scores").accessibilityIdentifier("hide-sign-scores")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(scores) { score in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(BasicLiveRecognition.display(score.label))
                                    .fontWeight(score.label == leader ? .bold : .regular)
                                Spacer(minLength: 0)
                                Text(score.similarity.map { String(format: "%.0f%%", $0*100) } ?? "—")
                                    .monospacedDigit()
                            }.font(.caption)
                            ProgressView(value: Double(score.similarity ?? 0))
                                .tint(score.label == leader ? Color.green : Color.white.opacity(0.75))
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(BasicLiveRecognition.display(score.label))
                        .accessibilityValue(score.similarity.map { String(format: "%.0f percent similarity, not probability", $0*100) }
                            ?? "No current score")
                        .accessibilityIdentifier("score-\(score.label)")
                    }
                }.padding(.bottom, 4)
            }.accessibilityIdentifier("sign-scores-list")
            Text("— needs usable movement · scroll for all 16")
                .font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 4)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sign-scores-panel")
    }
}
