import SwiftUI

struct ExpressionTesterView: View {
    @ObservedObject var tracker: SkeletonCameraTracker
    @Binding var engine: ExpressionCueEngine
    @Binding var paused: Bool
    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.78, green: 0.91, blue: 0.62)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    result
                    calibration
                    ForEach(ExpressionCue.allCases) { cue in cueCard(cue) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What this test measures").font(.headline)
                        Text("Facial movements select experimental presets. They do not tell us how you feel or what an ASL sign means. Lowered brows can also mark an ASL question.")
                        Text("Scores are movement levels, not emotion probabilities. Camera images and calibration stay on this device; calibration lasts for this app session. Recalibrate for a different person or camera angle.")
                        Text("Raw is the detector score. Level is the smoothed movement relative to your calibrated range. The white mark is the activation threshold.")
                        Button("Reset calibration & thresholds") { engine.resetCalibration() }
                            .accessibilityIdentifier("expression-reset")
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.06))
            .navigationTitle("Expression lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                }
            }
        }
        .preferredColorScheme(.dark).tint(accent)
        .onReceive(tracker.$skeleton) { frame in
            guard let frame, !paused else { engine.resetTracking(); return }
            engine.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                           coefficients: frame.expressions)
        }
        .onDisappear { engine.resetTracking() }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                if paused || !tracker.isRunning {
                    Color.black.opacity(0.65)
                    Text(paused ? "Camera paused" : tracker.status)
                        .font(.subheadline).padding(16)
                } else {
                    Label("Live · on device", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(8).background(.black.opacity(0.7), in: Capsule()).padding(12)
                }
            }.frame(height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 20))
            HStack {
                Text("One face, looking straight ahead").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    paused.toggle()
                    if paused { tracker.pause(); engine.resetTracking() } else { tracker.start() }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier("expression-pause")
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXPERIMENTAL PRESET").font(.caption.weight(.semibold)).foregroundStyle(accent)
            Text(resultTitle).font(.title2.bold()).accessibilityIdentifier("expression-result")
            Text(resultReason).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("expression-reason")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    }

    private var resultTitle: String {
        switch engine.decision {
        case .noFace: return paused ? "Paused" : "No face"
        case .unavailable: return "Signal unavailable"
        case .none: return "No clear cue"
        case .calibrating: return "Calibrating"
        case .holding(let cue): return "Hold \(cue.movement.lowercased())…"
        case .active(let cue): return "\(cue.title) preset"
        case .ambiguous: return "Ambiguous"
        }
    }

    private var resultReason: String {
        switch engine.decision {
        case .noFace: return "Keep your face in view. A missing face never selects a preset."
        case .unavailable: return "Waiting for a complete, fresh set of facial signals."
        case .none: return "No movement has stayed above its threshold for 300 ms."
        case .calibrating: return engine.calibration?.target.instruction ?? "Capturing movement range."
        case .holding(let cue): return "\(cue.movement) is above its threshold. Hold it for 300 ms."
        case .active(let cue): return "\(cue.movement) held above threshold → \(cue.title)."
        case .ambiguous(let cues): return cues.map(\.movement).joined(separator: " + ") + ". No preset selected."
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Relax, then calibrate").font(.headline)
            Text("Capture your relaxed face for two seconds. Then use the button on each cue to set its comfortable range.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let capture = engine.calibration {
                ProgressView(value: capture.progress)
                    .accessibilityLabel("Calibration progress")
                Text(capture.target.instruction).font(.subheadline.weight(.semibold))
                Button("Cancel capture") { engine.cancelCalibration() }
            } else {
                Button(engine.hasBaseline ? "Recapture relaxed face · 2 s" : "Capture relaxed face · 2 s") {
                    engine.startCalibration(.baseline)
                }.buttonStyle(.bordered).disabled(!engine.hasCompleteFace || paused)
                    .accessibilityIdentifier("expression-baseline")
                Text(engine.calibrationMessage).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("expression-calibration-message")
            }
        }
    }

    private func cueCard(_ cue: ExpressionCue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(cue.title).font(.headline)
                Spacer()
                if engine.decision == .active(cue) {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                } else if engine.peaks[cue] != nil {
                    Text("Calibrated").foregroundStyle(.secondary)
                } else {
                    Text("Default range").foregroundStyle(.secondary)
                }
            }.font(.caption)
            Text(cue.movement).font(.subheadline.weight(.medium))
            Text(cue.instruction).font(.caption).foregroundStyle(.secondary)
            GeometryReader { size in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(accent)
                        .frame(width: size.size.width * (engine.levels[cue] ?? 0))
                    Rectangle().fill(.white).frame(width: 2, height: 14)
                        .offset(x: max(0, (size.size.width - 2) * engine.threshold(for: cue)))
                }
            }.frame(height: 10).accessibilityHidden(true)
            Text("Raw \(number(engine.raw[cue])) · Level \(number(engine.levels[cue]))")
                .font(.system(.caption, design: .monospaced))
                .accessibilityIdentifier("expression-score-\(cue.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Activate %.2f · Release %.2f",
                            engine.threshold(for: cue), engine.releaseThreshold(for: cue)))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Lower = more sensitive").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { engine.threshold(for: cue) },
                                      set: { engine.setThreshold($0, for: cue) }),
                       in: 0.15...0.95, step: 0.01)
                    .accessibilityLabel("\(cue.title) activation threshold")
                    .accessibilityValue(String(format: "%.2f", engine.threshold(for: cue)))
                    .accessibilityIdentifier("expression-threshold-\(cue.id)")
                    .disabled(engine.calibration != nil)
            }
            Button("Calibrate \(cue.movement.lowercased()) · 2 s") {
                engine.startCalibration(.cue(cue))
            }.font(.subheadline).frame(minHeight: 44)
                .disabled(!engine.hasBaseline || !engine.hasCompleteFace || engine.calibration != nil || paused)
                .accessibilityIdentifier("expression-calibrate-\(cue.id)")
        }.padding(16).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    private func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
}
