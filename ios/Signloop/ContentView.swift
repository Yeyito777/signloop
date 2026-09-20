import SwiftUI

private enum CameraTheme {
    static let primary = Color(red: 0.78, green: 0.91, blue: 0.62)
    static let onPrimary = Color(red: 0.12, green: 0.19, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.11, blue: 0.09)
}

/// Offline sign/spelling research, skeleton inspection and frozen taught-expression inference.
struct ContentView: View {
    @StateObject private var tracker = SkeletonCameraTracker()
    @StateObject private var recognition = BasicLiveRecognition(activeLabels: BasicSignScore.presentationVocabulary,
                                                               weMotionScale: BasicSignMatcher.compactWEMotionScale)
    @StateObject private var alphabet = AlphabetRecognition(allowedLetters: AlphabetModel.aurelioLetters)
    @State private var spelling = false
    @State private var draft = SpellingDraft(allowedLetters: AlphabetModel.aurelioLetters)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var paused = false
    @State private var showSettings = false
    @State private var showProbe = false
    @State private var showExpressions = false
    @State private var expressionRuntime = TaughtExpressionRuntime(profile: TaughtExpressionStore.standard.load())
    @State private var probe = SkeletonProbe()
    @AppStorage("showTrackingStats") private var showTrackingStats = false
    @AppStorage("showAllSignScores") private var showAllSignScores = false
    @State private var showAllCandidates = false
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                    LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    if tracker.isRunning && !paused {
                        SkeletonOverlay(frame: tracker.skeleton, mirrored: tracker.isFront,
                            showHands: tracker.showJoints, showPose: tracker.showPose,
                            showFace: tracker.showFace, showNumbers: tracker.showNumbers, selected: probe) {
                                probe = $0
                                showProbe = true
                            }
                    }
                    if paused { Color.black.opacity(0.55) }
                }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.ignoresSafeArea()
            if tracker.permissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("See your movement").font(.title2.bold())
                    Button("Allow camera in Settings") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }.buttonStyle(.borderedProminent).foregroundStyle(CameraTheme.onPrimary)
                }.padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            } else if tracker.errorMessage != nil {
                Button("Camera unavailable · tap to retry") { paused = false; tracker.start() }
                    .padding().background(.ultraThinMaterial, in: Capsule())
            }
            // UI respects header/controls safe areas; only the camera itself
            // extends behind them. Keep the close button clear of the notch.
            if showAllSignScores && !spelling {
                GeometryReader { geometry in
                    VStack {
                        SignScoresPanel(scores: recognition.scores, isPresented: $showAllSignScores,
                                        showAll: $showAllCandidates)
                            .frame(height: min(showAllCandidates || dynamicTypeSize.isAccessibilitySize ? 340 : 210,
                                               max(0, geometry.size.height-16)))
                            .padding(.horizontal, 12).padding(.top, 8)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .background(.black).foregroundStyle(.white).tint(CameraTheme.primary)
        .onAppear {
            // A saved expression profile needs face landmarks; word-only sessions
            // retain the optional face-off performance setting.
            if expressionRuntime.profile != nil { tracker.trackFace = true }
            connectRecognition()
            tracker.onSkeletonReset = { recognition.reset(); alphabet.reset() }
            recognition.load()
            alphabet.load()
            tracker.start()
        }
        .onChange(of: spelling) { _, _ in
            recognition.reset(); alphabet.reset()
            connectRecognition()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !paused { tracker.start() } else { tracker.pause(); expressionRuntime.resetTracking() }
        }
        .onReceive(clock) { _ in tracker.expireLocalResult() }
        .onReceive(tracker.$skeleton) { frame in
            guard let frame, !paused else { expressionRuntime.resetTracking(); return }
            expressionRuntime.observe(timestampMS: frame.timestampMS, hasFace: frame.hasFace,
                                      observation: ExpressionObservation.from(frame, measurement: expressionRuntime.profile?.measurement ?? .current))
        }
        .onChange(of: paused) { _, value in if value { expressionRuntime.resetTracking() } }
        .onDisappear { tracker.pause() }
        .sheet(isPresented: $showSettings) {
            CameraSettings(tracker: tracker, recognition: recognition, showTrackingStats: $showTrackingStats,
                           showAllSignScores: $showAllSignScores, alphabet: alphabet)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProbe) {
            SkeletonInspector(tracker: tracker, probe: $probe)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExpressions) {
            ExpressionTesterView(tracker: tracker, runtime: $expressionRuntime, paused: $paused)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    private func connectRecognition() {
        let useLetters = spelling
        tracker.onSkeletonFrame = { frame in
            if useLetters { alphabet.receive(frame) } else { recognition.receive(frame) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Honk & Tell").font(.title2.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.65)
                Spacer()
                if TaughtExpressionStore.trainingEnabled {
                    Button { tracker.trackFace = true; showExpressions = true } label: {
                        Image(systemName: "face.smiling").frame(width: 48, height: 48)
                            .background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Expression lab").accessibilityIdentifier("expression-lab")
                }
                Button { showProbe = true } label: {
                    Image(systemName: "scope").frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }.accessibilityLabel("Inspect skeleton").accessibilityIdentifier("skeleton-inspector")
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }.accessibilityLabel("Settings").accessibilityIdentifier("camera-settings")
            }
            if showTrackingStats {
                Text("\(tracker.fps) FPS · \(tracker.latencyMS) ms tracking · \(spelling ? alphabet.matchMS : recognition.matchMS) ms match")
                    .font(.system(.caption, design: .monospaced))
                    .padding(10).background(.ultraThinMaterial, in: Capsule())
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Picker("Recognition mode", selection: $spelling) {
                    Text("Signs").tag(false)
                    Text("Spell name").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("recognition-mode")
                Text(paused ? "Paused" : spelling ? "Letter guess" : recognition.ready ? "Best guess" : "Live skeleton").font(.title3.weight(.semibold))
                    .accessibilityIdentifier("tracking-title")
                if !paused {
                    Text(spelling ? alphabet.letter ?? "Watching…" :
                            recognition.sign.map(BasicLiveRecognition.display) ?? (recognition.ready ? "Watching…" : "Tracking"))
                        .font(.title.weight(.bold)).accessibilityIdentifier("current-sign")
                    Text(spelling && dynamicTypeSize.isAccessibilitySize && alphabet.ready
                         ? (alphabet.letter == nil ? "Hold one hand" : "Check, then Add")
                         : spelling ? alphabet.detail : recognition.detail).font(.caption).multilineTextAlignment(.center)
                        .accessibilityIdentifier("recognition-status")
                }
                if spelling {
                    Text(draft.text.isEmpty ? "Spelling…" : draft.text)
                        .font(.headline.monospaced()).lineLimit(2)
                        .accessibilityIdentifier("spelling-draft")
                    HStack(spacing: 12) {
                        Button {
                            if let letter = alphabet.letter { draft.append(letter) }
                        } label: {
                            if dynamicTypeSize.isAccessibilitySize {
                                Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                            } else {
                                Text("Add \(alphabet.letter ?? "letter")").frame(minHeight: 44)
                            }
                        }.accessibilityLabel("Add \(alphabet.letter ?? "letter")")
                            .disabled(paused || alphabet.letter == nil)
                            .accessibilityIdentifier("add-letter")
                        Button { draft.backspace() } label: { Image(systemName: "delete.left").frame(minWidth: 44,minHeight: 44) }
                            .accessibilityLabel("Delete last letter").accessibilityIdentifier("delete-letter")
                        Menu {
                            ForEach(alphabet.allowedLetters, id: \.self) { letter in
                                Button("\(letter) (manual)") { draft.append(letter) }
                            }
                            Button("Clear spelling", role: .destructive) { draft.clear() }
                        } label: {
                            Image(systemName: "keyboard").frame(minWidth: 44,minHeight: 44)
                        }.accessibilityLabel("Manual letters and clear").accessibilityIdentifier("manual-spelling")
                    }.buttonStyle(.bordered).controlSize(.regular)
                    Text(dynamicTypeSize.isAccessibilitySize ? "AURELIO only" :
                            "A U R E L I O only · confirm each letter")
                        .font(.caption2).multilineTextAlignment(.center)
                        .accessibilityIdentifier("analysis-mode")
                }
                if !spelling {
                HStack(spacing: 14) {
                    trackingBadge("Hands \(tracker.skeleton?.hands.count ?? 0)/2",
                                  active: !(tracker.skeleton?.hands.isEmpty ?? true))
                    trackingBadge("Body", active: tracker.skeleton?.hasPose ?? false)
                    trackingBadge(tracker.trackFace ? "Face" : "Face off", active: tracker.skeleton?.hasFace ?? false)
                }.font(.caption.weight(.semibold))
                if expressionRuntime.profile != nil {
                    Text(expressionRuntime.result.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(CameraTheme.primary).accessibilityIdentifier("live-expression-preset")
                }
                Text(paused ? "Camera and tracking paused" : tracker.status)
                    .font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("tracking-status")
                Text("Offline · \(recognition.labels.count)-sign research preview · tap a point to inspect")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("analysis-mode")
                }
            }.frame(maxWidth: .infinity).padding(14)
                .background(CameraTheme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 24))
            HStack(spacing: 12) {
                Button {
                    paused.toggle()
                    if paused { tracker.pause() } else { tracker.start() }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(CameraTheme.onPrimary).background(CameraTheme.primary, in: Capsule())
                }.accessibilityIdentifier("pause-resume")
                Button { tracker.flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22)).frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }.disabled(!tracker.isRunning || paused).accessibilityLabel("Switch camera")
            }
        }.frame(maxWidth: 520).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    private func trackingBadge(_ name: String, active: Bool) -> some View {
        Label(name, systemImage: active ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(active ? CameraTheme.primary : .white)
            .accessibilityLabel("\(name): \(active ? "tracked" : "not detected")")
    }
}

private struct CameraSettings: View {
    @ObservedObject var tracker: SkeletonCameraTracker
    @ObservedObject var recognition: BasicLiveRecognition
    @Binding var showTrackingStats: Bool
    @Binding var showAllSignScores: Bool
    @ObservedObject var alphabet: AlphabetRecognition
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Camera overlays") {
                    Toggle("Show match scores", isOn: $showAllSignScores)
                        .accessibilityIdentifier("show-all-sign-scores")
                    Text("Shows the three closest matches; tap All to inspect every sign. Each distance is measured independently: lower is closer, not more certain. Adding signs does not divide existing scores. Even the closest match can be wrong.")
                        .font(.footnote)
                    Toggle("Track face (slower)", isOn: $tracker.trackFace)
                    Text("Hands and shoulders/chest stay tracked. Face is optional and off by default for word matching.")
                        .font(.footnote)
                    Toggle("Show hand joints", isOn: $tracker.showJoints)
                    Toggle("Show upper-body pose", isOn: $tracker.showPose)
                    Toggle("Show facial features", isOn: $tracker.showFace)
                    Toggle("Show joint numbers", isOn: $tracker.showNumbers)
                    Toggle("Show tracking stats", isOn: $showTrackingStats)
                    Text("Cyan: body. Yellow: face. Mint/orange: hands matched to left/right pose wrists. White: unassigned hand. Dashed lines are approximate wrist associations.")
                        .font(.footnote)
                }
                Section("Fingerspelling") {
                    Text("Choose Spell name. Only A, U, R, E, L, I and O can be recognized or entered. Show one hand, hold a letter, then tap Add after checking it. Other letters are excluded before selecting a guess. This restricted mode cannot spell SIGNLOOP.")
                    Toggle("Mirror letter input", isOn: $alphabet.mirrorInput)
                    Text("Off matches the source collection scripts’ unmirrored coordinates. Try the other setting if signing-hand orientation differs. Names stay in memory only; no server, autocorrect or saved transcript.")
                    Text("Alphabet data/features: Siruyy/realtime-asl-recognizer · MIT · © 2026 Neria. Signloop-trained model; experimental, not verified for a fresh signer.")
                }.font(.footnote)
                Section("On-device tracking") {
                    LabeledContent("Hand points", value: "\(tracker.skeleton?.hands.reduce(0) { $0 + $1.points.count } ?? 0) / 42")
                    LabeledContent("Upper-body points", value: "\(tracker.skeleton?.pose.filter(\.usable).count ?? 0) / 25")
                    LabeledContent("Face points", value: "\(tracker.skeleton?.face.count ?? 0) / 478")
                    LabeledContent("Tracking rate", value: "\(tracker.fps) FPS")
                    LabeledContent("Inference", value: "\(tracker.latencyMS) ms")
                    LabeledContent("Camera frame age", value: tracker.frameAgeMS.map { "\($0) ms" } ?? "—")
                    if let error = tracker.errorMessage { Text(error).font(.footnote) }
                }
                Section("What this build does") {
                    Text("Tracks up to two hands, one upper body and one face. Stand alone with your head, hands and hips in view. Hidden or uncertain points are not drawn.")
                    Text("A taught demo profile compares facial measurements with your saved examples; it does not infer feelings or ASL meaning. Expression lab enables face tracking, which can add latency.")
                    Text("The top candidate is always shown when usable movement is available—even if it is uncertain or the input is not a supported sign. Watching means more tracking evidence is needed. No transcription or sentences yet.")
                    Text("Offline only: no images or video are recorded or sent to a server. Up to 2.4 seconds of landmarks stay in memory and clear on pause, camera switch or stale capture. Expression lab explicitly saves numeric calibration examples and check results on this phone. Export shares only that numeric profile. Camera observations never retrain the saved profile.")
                        .accessibilityIdentifier("offline-privacy")
                }.font(.footnote)
                Section("Try one sign at a time") {
                    Text(recognition.labels.map(BasicLiveRecognition.display).joined(separator: " · "))
                    Text("WE: point your index finger toward your upper chest and make a small arc from one side to the other. Keep the hand visible; no exaggerated sweep needed.")
                    Text("Frame your face, shoulders and both hands. Sign naturally, then briefly relax. This small research matcher will miss signs and may confuse similar ones; it is not a validated communication aid.")
                }.font(.footnote)
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }
    }
}

private struct SkeletonInspector: View {
    @ObservedObject var tracker: SkeletonCameraTracker
    @Binding var probe: SkeletonProbe
    @Environment(\.dismiss) private var dismiss
    private let channels = ["browInnerUp", "browDownLeft", "browDownRight", "eyeBlinkLeft",
                            "eyeBlinkRight", "jawOpen", "mouthPucker", "mouthSmileLeft", "mouthSmileRight"]
    var body: some View {
        NavigationStack {
            Form {
                Section("Live point probe") {
                    Picker("Part", selection: $probe.part) {
                        Text("Upper body").tag("pose")
                        Text("Left hand (pose-matched)").tag("Left")
                        Text("Right hand (pose-matched)").tag("Right")
                        Text("Hand slot 0 (this frame)").tag("hand0")
                        Text("Hand slot 1 (this frame)").tag("hand1")
                        Text("Face").tag("face")
                    }.onChange(of: probe.part) { _, _ in probe.id = 0 }
                    Stepper("Landmark \(probe.id)", value: $probe.id,
                            in: 0...(probe.part == "face" ? 477 : probe.part == "pose" ? 24 : 20))
                    Text(probe.title).font(.headline)
                    if let p = tracker.skeleton?.point(probe) {
                        Text(String(format: "x %.3f · y %.3f · z %.3f", p.x, p.y, p.z))
                            .font(.system(.body, design: .monospaced))
                        LabeledContent("Visibility", value: p.visibility.map { String(format: "%.2f", $0) } ?? "Not provided")
                        LabeledContent("Presence", value: p.presence.map { String(format: "%.2f", $0) } ?? "Not provided")
                    } else {
                        Text("Not detected in the current frame").accessibilityIdentifier("probe-missing")
                    }
                    Text("Image x/y are unmirrored and normalized. Selfie preview is mirrored only for display. Depth is relative to each detector, not a common 3D coordinate. Hand slots may reorder; pose association is approximate.")
                        .font(.footnote)
                }
                Section("Facial movement · not emotions") {
                    ForEach(channels, id: \.self) { name in
                        LabeledContent(name, value: tracker.skeleton?.expressions[name].map { String(format: "%.2f", $0) } ?? "—")
                    }
                    Text("0–1 blendshape coefficients; not calibrated probabilities or sentiment labels. All returned channels are available in the in-memory SkeletonFrame.")
                        .font(.footnote)
                }
                Section("Synchronized frame") {
                    LabeledContent("Capture timestamp (ms)", value: tracker.skeleton.map { String($0.timestampMS) } ?? "—")
                    LabeledContent("Frames in RAM", value: "\(tracker.bufferedFrames)")
                    ForEach(["hands", "pose", "face"], id: \.self) { name in
                        LabeledContent("\(name.capitalized) inference", value: tracker.skeleton?.timingsMS[name].map { String(format: "%.1f ms", $0) } ?? "—")
                    }
                    Text("Three detectors, same camera frame. Offline temporal matching; no recording, upload or transcription.").font(.footnote)
                }
            }.navigationTitle("Skeleton inspector").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }
    }
}
