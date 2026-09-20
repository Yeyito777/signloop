import SwiftUI
import UniformTypeIdentifiers

struct ExpressionProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        _ = try TaughtExpressionStore.decode(data)
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
    @Environment(\.dismiss) private var dismiss
    @State private var teacher: ExpressionTeacher?
    @State private var showExport = false
    @State private var showImport = false
    @State private var exportDocument: ExpressionProfileDocument?
    @State private var transferMessage = ""
    private let accent = Color(red: 0.78, green: 0.91, blue: 0.62)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LIVE EXPRESSION").font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(runtime.result.title).font(.title2.bold()).accessibilityIdentifier("expression-result")
                        Text(runtime.profile == nil ? "No taught profile is installed yet. Setup stays here in the experimental lab." : "Using your saved examples. Normal use never changes your profile.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.card()
                    if teacher != nil { teaching } else { profile }
                    movementFeedback
                    Text("These are labels for the expressions you teach, not a reading of your feelings or ASL meaning. Images and video are never saved or uploaded. The profile contains only numeric examples and check results.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Expression lab · jaw drop & nose scrunch · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("expression-build")
                }.padding(20)
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.06))
            .navigationTitle("Expression lab").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }
        .preferredColorScheme(.dark).tint(accent)
        .onReceive(tracker.$skeleton) { frame in
            guard let frame, !paused else { teacher?.interrupt(); return }
            teacher?.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                             observation: ExpressionObservation.from(frame))
        }
        .onDisappear { teacher?.interrupt() }
        .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                      defaultFilename: "DemoExpressionProfile") { result in
            switch result {
            case .success: transferMessage = "Profile exported. It can now be bundled into the demo build."
            case .failure(let error): transferMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let profile = try TaughtExpressionStore.read(url)
                try runtime.install(profile)
                transferMessage = "Demo profile imported and saved on this phone."
            } catch { transferMessage = "Import failed: \(error.localizedDescription) Your previous profile is unchanged." }
        }
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
            Button(runtime.profile == nil ? "Teach my expressions" : runtime.needsJawDropRetake ? "Teach a jaw-drop profile" : "Teach a replacement profile") { teacher = ExpressionTeacher() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("expression-teach")
            Button("Export demo profile") {
                do {
                    guard let profile = runtime.profile else { return }
                    exportDocument = ExpressionProfileDocument(data: try TaughtExpressionStore.encode(profile))
                    showExport = true
                } catch { transferMessage = error.localizedDescription }
            }.disabled(runtime.profile == nil).accessibilityIdentifier("expression-export")
            Button("Import demo profile") { showImport = true }.accessibilityIdentifier("expression-import")
            if !transferMessage.isEmpty { Text(transferMessage).font(.caption).accessibilityIdentifier("expression-transfer-message") }
        }.card()
    }

    private var teaching: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let teacher {
                Text("Teach my expressions").font(.headline)
                ProgressView(value: Double(teacher.completedSteps), total: 18)
                Text("\(teacher.completedSteps) of 18 takes complete").font(.caption).accessibilityIdentifier("expression-teaching-progress")
                if let step = teacher.nextStep {
                    Text(step.title).font(.title3.bold()).accessibilityIdentifier("expression-teaching-step")
                    Text(step.label.instruction).font(.subheadline)
                    if step.isValidation { Text("This is a fresh check. It won't change your teaching examples.").font(.caption).foregroundStyle(.secondary) }
                    if let capture = teacher.capture {
                        Text(capture.preparing ? "Get ready…" : "Hold steady…").font(.headline)
                        ProgressView(value: capture.progress)
                    } else {
                        Button("Capture this expression · 3 s") { self.teacher?.startCapture() }
                            .buttonStyle(.borderedProminent).disabled(!teacher.readyForCapture || paused)
                            .accessibilityIdentifier("expression-capture")
                    }
                }
                Text(teacher.message).font(.subheadline).accessibilityIdentifier("expression-teaching-message")
                if let candidate = teacher.candidate {
                    Button("Use this profile for the demo") {
                        do { try runtime.install(candidate); self.teacher = nil; transferMessage = "Your fixed demo profile is saved. Export it before moving to another build or phone." }
                        catch { transferMessage = "Couldn't save: \(error.localizedDescription). Your old profile is unchanged." }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("expression-save-profile")
                    if !transferMessage.isEmpty { Text(transferMessage).font(.caption) }
                }
                DisclosureGroup("Retake an expression") {
                    ForEach(TaughtExpressionLabel.allCases) { label in
                        Button("Retake \(label.title.lowercased())") { self.teacher?.retake(label) }
                            .frame(minHeight: 44).disabled(teacher.capture != nil)
                    }
                }
                Button("Cancel setup") { self.teacher = nil }
                    .accessibilityIdentifier("expression-cancel-teaching")
                Text("Your installed profile is kept until all checks pass and you save this replacement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card()
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
