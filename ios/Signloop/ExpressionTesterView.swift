import SwiftUI
import UniformTypeIdentifiers

struct ExpressionProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if ExpressionTeacher.isSetupExport(data) { _ = try ExpressionTeacher.restoreSetup(data) }
        else { _ = try TaughtExpressionStore.decode(data) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Developer-only teaching surface. Demo builds hide this entry point entirely.
struct ExpressionTesterView: View {
    @ObservedObject var tracker: SkeletonCameraTracker
    @Binding var runtime: TaughtExpressionRuntime
    @Binding var paused: Bool
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var teacher: ExpressionTeacher?
    @State private var showExport = false
    @State private var showImport = false
    @State private var exportDocument: ExpressionProfileDocument?
    @State private var exportFilename = "ExpressionSetupProgress"
    @State private var exportCompletionMessage = ""
    @State private var transferMessage = ""
    private let accent = Color(red: 0.78, green: 0.91, blue: 0.62)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    if !transferMessage.isEmpty {
                        Text(transferMessage).font(.subheadline)
                            .accessibilityIdentifier("expression-transfer-message")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LIVE EXPRESSION").font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(runtime.result.title).font(.title2.bold()).accessibilityIdentifier("expression-result")
                        Text(runtime.profile == nil ? "No taught profile is installed yet. Setup stays here in the experimental lab." : "Using your saved examples. Normal use never changes your profile.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.card()
                    if teacher != nil { teaching } else { profile }
                    Button("Import profile or setup progress") {
                        teacher?.interrupt(); showImport = true
                    }.accessibilityIdentifier("expression-import")
                    movementFeedback
                    Text("These are labels for the expressions you teach, not a reading of your feelings or ASL meaning. Images and video are never saved or uploaded. The profile contains only numeric examples and check results.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Expression lab · jaw drop & nose scrunch · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("expression-build")
                }.padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { nextActionPanel }
            .background(Color(red: 0.05, green: 0.07, blue: 0.06))
            .navigationTitle("Expression lab").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if teacher != nil || runtime.profile == nil {
                            Button("Export setup progress") { exportSetup() }
                                .accessibilityIdentifier("expression-export-setup")
                        }
                        if let candidate = teacher?.candidate {
                            Button("Export checked demo profile") { exportProfile(candidate) }
                                .accessibilityIdentifier("expression-export-checked")
                        }
                        if let saved = runtime.profile {
                            Button("Export saved demo profile") { exportProfile(saved) }
                                .accessibilityIdentifier("expression-export-saved")
                        }
                    } label: { Text("Export") }
                    .accessibilityIdentifier("expression-export")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") {
                    if let onDone { onDone() } else { dismiss() }
                }.frame(minHeight: 44) }
            }
        }
        .preferredColorScheme(.dark).tint(accent)
        .onReceive(tracker.$skeleton) { frame in
            guard let frame, !paused else { teacher?.interrupt(); return }
            teacher?.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                             observation: ExpressionObservation.from(frame))
        }
        .onDisappear { teacher?.interrupt() }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success: transferMessage = exportCompletionMessage
            case .failure(let error): transferMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 262_144 else { throw ExpressionTeachingError(message: "Expression file is too large.") }
                let data = try Data(contentsOf: url)
                if ExpressionTeacher.isSetupExport(data) {
                    let restored = try ExpressionTeacher.restoreSetup(data)
                    teacher = restored
                    transferMessage = "Setup progress restored. Your saved demo profile stays active until you finish and save this setup."
                } else {
                    try runtime.install(TaughtExpressionStore.decode(data))
                    teacher = nil
                    transferMessage = "Demo profile imported and saved on this phone."
                }
            } catch { transferMessage = "Import failed: \(error.localizedDescription) Your current setup and saved profile are kept." }
        }
    }

    private func exportSetup() {
        teacher?.interrupt()
        do {
            exportDocument = ExpressionProfileDocument(data: try (teacher ?? ExpressionTeacher()).exportSetup())
            exportFilename = "ExpressionSetupProgress"
            exportCompletionMessage = "Setup progress exported. Import this file to continue from your completed takes and checks."
            showExport = true
        } catch { transferMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func exportProfile(_ profile: TaughtExpressionProfile) {
        teacher?.interrupt()
        do {
            exportDocument = ExpressionProfileDocument(data: try TaughtExpressionStore.encode(profile))
            exportFilename = "DemoExpressionProfile"
            exportCompletionMessage = "Checked demo profile exported. It can be imported on another phone or bundled into the demo build."
            showExport = true
        } catch { transferMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func saveProfile(_ profile: TaughtExpressionProfile) {
        do {
            try runtime.install(profile); teacher = nil
            transferMessage = "Your fixed demo profile is saved. Export the saved demo profile from the toolbar to back it up."
        } catch { transferMessage = "Couldn't save: \(error.localizedDescription). Your previous profile is kept." }
    }

    private var nextActionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let teacher {
                if let candidate = teacher.candidate {
                    Text("Next: save your checked profile").font(.headline).accessibilityIdentifier("expression-next-step")
                    Text("All six checks passed. Save to activate it, or export the checked profile from the toolbar.").font(.caption)
                    Button("Use this profile for the demo") { saveProfile(candidate) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-save-profile")
                } else if let step = teacher.nextStep {
                    Text("Next: \(step.title)").font(.headline).accessibilityIdentifier("expression-next-step")
                    Text(step.instruction).font(.caption)
                    if let capture = teacher.capture {
                        Text(capture.preparing ? "Get ready — make the expression now." : "Hold it steady until the bar finishes.").font(.subheadline.bold())
                        ProgressView(value: capture.progress)
                    } else if paused {
                        Text("Resume the camera to continue this take.").font(.caption)
                        Button("Resume camera") { paused = false; tracker.start() }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-resume")
                    } else {
                        Text(step.timingInstruction).font(.caption).foregroundStyle(.secondary)
                        if !teacher.readyForCapture {
                            if tracker.permissionDenied {
                                Button("Allow camera in Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                            } else if tracker.errorMessage != nil {
                                Button("Retry camera") { tracker.start() }
                            } else {
                                Text("\(teacher.readinessInstruction) Capture becomes available when tracking is ready.").font(.caption)
                            }
                        }
                        Button(step.isValidation ? "\(teacher.failures[step.label] == nil ? "Start" : "Retry") check \(step.checkNumber) of 6" : "Capture take \(step.take) of 2") {
                            self.teacher?.startCapture()
                        }.buttonStyle(.borderedProminent).disabled(!teacher.readyForCapture)
                            .accessibilityIdentifier("expression-capture")
                    }
                } else if let label = teacher.attentionLabels.first(where: { $0 != .neutral }) ?? teacher.attentionLabels.first {
                    Text("Next: retake \(label.title.lowercased())").font(.headline).accessibilityIdentifier("expression-next-step")
                    Text("The teaching examples need a fix before the six checks can start. See the reason in the checklist.").font(.caption)
                    Button(label == .neutral ? "Retake relaxed face · restart setup" : "Retake \(label.title.lowercased())") { self.teacher?.retake(label) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-next-retake")
                } else {
                    Text("Next: review the teaching issue").font(.headline).accessibilityIdentifier("expression-next-step")
                    Text(teacher.message).font(.caption)
                }
            } else {
                Text(runtime.profile == nil ? "Next: teach your expressions" : "Next: use or export your saved profile")
                    .font(.headline).accessibilityIdentifier("expression-next-step")
                Text(runtime.profile == nil ? "Start with two takes of each expression, then follow the six guided checks. Export progress whenever you need to stop." : "Your profile is active. Tap Done to use it, or Export to back it up.")
                    .font(.caption)
                if runtime.profile == nil {
                    Button("Teach my expressions") { teacher = ExpressionTeacher() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-teach")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(red: 0.07, green: 0.10, blue: 0.08))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                if paused || !tracker.isRunning {
                    Color.black.opacity(0.65)
                    Text(paused ? "Camera paused" : tracker.status).padding(16)
                } else {
                    Text("Live · on device").font(.caption.weight(.semibold))
                        .padding(8).background(.black.opacity(0.7), in: Capsule()).padding(12)
                }
            }.frame(height: 160).clipped().clipShape(RoundedRectangle(cornerRadius: 20))
            HStack {
                Text("One face, looking straight ahead").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    paused.toggle()
                    if paused { tracker.pause(); teacher?.interrupt() } else { tracker.start() }
                } label: { Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") }
                .frame(minHeight: 44).accessibilityIdentifier("expression-pause")
            }
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(runtime.profile == nil ? "Teach once. Reuse for the demo." : "Your demo profile is saved").font(.headline)
            if let profile = runtime.profile {
                Text("Six expressions checked · saved \(profile.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("It loads automatically, including after you close the app. Export it to use the same face profile in a demo build with no setup screens.")
                    .font(.subheadline)
                if runtime.needsJawDropRetake {
                    Text("Your saved profile uses widened eyes for fear. Teach one replacement profile to use a jaw drop for fear and a nose scrunch for disgust. Your current profile stays active until you save it.")
                        .font(.subheadline).foregroundStyle(accent)
                } else if runtime.needsSensitivityRetake {
                    Text("Your earlier profile is still active. Teach a replacement using comfortable, steady expressions to enable the more sensitive brow and eye matching.")
                        .font(.subheadline).foregroundStyle(accent)
                }
            } else {
                Text("Teach your relaxed face and five expressions. Two takes each, then six repeat checks. Your saved profile becomes the recognizer's fixed reference.")
                    .font(.subheadline)
            }
            if runtime.profile != nil {
                Button(runtime.needsJawDropRetake ? "Teach a jaw-drop profile" : "Teach a replacement profile") { teacher = ExpressionTeacher() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-teach")
            }
            Text("Export setup progress at any time to continue later. A checked demo profile is available after all six checks pass.")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    private var teaching: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let teacher {
                Text("Teach my expressions").font(.headline)
                ProgressView(value: Double(teacher.completedSteps), total: 18)
                Text("\(teacher.completedSteps) of 18 takes complete").font(.caption).accessibilityIdentifier("expression-teaching-progress")
                Text("\(teacher.teachingTakeCount)/12 teaching captures · \(teacher.validation.count)/6 checks passed")
                    .font(.subheadline).accessibilityIdentifier("expression-teaching-breakdown")
                if !teacher.attentionLabels.isEmpty {
                    Label("Needs attention: \(teacher.attentionLabels.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.bold()).foregroundStyle(.orange)
                        .accessibilityIdentifier("expression-teaching-attention")
                } else if teacher.teachingTakeCount == 12 && teacher.validation.count < 6 {
                    Text("Teaching captures are saved. Now repeat each expression once to check it.")
                        .font(.subheadline)
                }
                if let step = teacher.nextStep {
                    Text(step.title).font(.title3.bold()).accessibilityIdentifier("expression-teaching-step")
                    Text(step.instruction).font(.subheadline)
                    if step.isValidation {
                        Text("Repeat the expression you taught, at the same camera angle. This fresh take checks recognition without changing your examples. After it passes, relax and follow the next named check below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(teacher.message).font(.subheadline).accessibilityIdentifier("expression-teaching-message")
                teachingChecklist(teacher)
                Button("Cancel setup") { self.teacher = nil }
                    .accessibilityIdentifier("expression-cancel-teaching")
                Text("Your installed profile is kept until all checks pass and you save this replacement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    private func teachingChecklist(_ teacher: ExpressionTeacher) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Expression checklist").font(.headline)
            Text("Each expression needs two teaching captures and one passed check. Captured does not mean checked.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(TaughtExpressionLabel.allCases) { label in
                let status = teacher.status(for: label)
                let failure = teacher.failures[label]
                let count = teacher.examples[label, default: []].count
                VStack(alignment: .leading, spacing: 6) {
                    Text(label.title).font(.subheadline.bold())
                    Text("Teaching: \(count)/2 captured").font(.caption)
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: status == .passed ? "checkmark.circle.fill" : failure != nil ? "exclamationmark.triangle" : "clock")
                            .accessibilityHidden(true)
                        Text(status.title).accessibilityIdentifier("expression-status-\(label.rawValue)")
                    }.font(.subheadline)
                        .foregroundStyle(status == .passed ? accent : failure != nil ? .orange : .secondary)
                    if let failure {
                        Text(failure.reason).font(.caption)
                            .accessibilityIdentifier("expression-issue-\(label.rawValue)")
                    }
                    if teacher.nextStep?.label == label {
                        Text(teacher.capture == nil ? "Up next" : "Capturing now…")
                            .font(.caption.bold()).foregroundStyle(accent)
                    }
                    if count > 0 {
                        Button(label == .neutral ? "Retake relaxed face · restart setup" : "Retake \(label.title.lowercased())") {
                            self.teacher?.retake(label)
                        }.buttonStyle(.bordered).frame(minHeight: 44)
                            .disabled(teacher.capture != nil)
                            .accessibilityIdentifier("expression-retake-\(label.rawValue)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if label != TaughtExpressionLabel.allCases.last { Divider() }
            }
            Text("Retaking an expression keeps the other teaching captures, but all six checks must be repeated. Retaking your relaxed face restarts the whole setup.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var movementFeedback: some View {
        let observation = teacher != nil ? teacher?.observation : runtime.observation
        let usesJaw = teacher != nil || runtime.profile?.measurement?.usesJaw != false
        let cues: [ExpressionCue] = teacher != nil || !runtime.needsNoseScrunchRetake ? [.anger, .fear, .disgust] : [.anger, .fear]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Your facial movement").font(.headline)
            Text("Measured against your relaxed face. 100% means the movement in your taught example, not confidence or a required score.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(cues) { cue in
                let reading = ExpressionMovementReading.make(cue: cue, observation: observation,
                    examples: teacher?.examples ?? runtime.profile?.examples ?? [:])
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(cue == .anger ? "Brow lowering" : cue == .fear ? (usesJaw ? "Jaw drop" : "Eye opening") : "Nose scrunch")
                        Spacer()
                        if let fraction = reading?.fraction {
                            Text("\(Int(max(-9.99, min(9.99, fraction))*100))% of taught change").monospacedDigit()
                        }
                    }.font(.subheadline)
                    if let reading {
                        if let fraction = reading.fraction {
                            ProgressView(value: max(0, min(1, fraction)))
                        }
                        Text("Change from relaxed: \(reading.change, specifier: "%+.4f")\(reading.fraction == nil ? " · Capture this expression to set its range." : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(observation == nil ? "Waiting for a tracked face." : "Capture your relaxed face first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("expression-movement-\(cue.rawValue)")
            }
            Text("Small numbers can be meaningful. Matches also use the rest of your taught expression and ignore movement within your relaxed-face variation.")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }
}
