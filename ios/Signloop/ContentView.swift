import SwiftUI

private enum CameraTheme {
    static let primary = Color(red: 0.78, green: 0.91, blue: 0.62)
    static let onPrimary = Color(red: 0.12, green: 0.19, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.11, blue: 0.09)
}

/// Tracking only. No sign classifier, transcription, backend or file export.
struct ContentView: View {
    @StateObject private var tracker = SkeletonCameraTracker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false
    @State private var showSettings = false
    @State private var showProbe = false
    @State private var showExpressions = false
    @State private var expressionEngine = ExpressionCueEngine()
    @State private var probe = SkeletonProbe()
    @AppStorage("showTrackingStats") private var showTrackingStats = false
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
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .background(.black).foregroundStyle(.white).tint(CameraTheme.primary)
        .onAppear { tracker.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !paused { tracker.start() } else { tracker.pause() }
        }
        .onReceive(clock) { _ in tracker.expireLocalResult() }
        .onDisappear { tracker.pause() }
        .sheet(isPresented: $showSettings) {
            CameraSettings(tracker: tracker, showTrackingStats: $showTrackingStats)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProbe) {
            SkeletonInspector(tracker: tracker, probe: $probe)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExpressions) {
            ExpressionTesterView(tracker: tracker, engine: $expressionEngine, paused: $paused)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("signloop").font(.title2.weight(.semibold))
                Spacer()
                Button { showExpressions = true } label: {
                    Image(systemName: "face.smiling").frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }.accessibilityLabel("Expression lab").accessibilityIdentifier("expression-lab")
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
                Text("\(tracker.fps) FPS · \(tracker.latencyMS) ms inference · age \(tracker.frameAgeMS.map(String.init) ?? "—") ms")
                    .font(.system(.caption, design: .monospaced))
                    .padding(10).background(.ultraThinMaterial, in: Capsule())
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text(paused ? "Paused" : "Live skeleton").font(.title3.weight(.semibold))
                    .accessibilityIdentifier("tracking-title")
                HStack(spacing: 14) {
                    trackingBadge("Hands \(tracker.skeleton?.hands.count ?? 0)/2",
                                  active: !(tracker.skeleton?.hands.isEmpty ?? true))
                    trackingBadge("Body", active: tracker.skeleton?.hasPose ?? false)
                    trackingBadge("Face", active: tracker.skeleton?.hasFace ?? false)
                }.font(.caption.weight(.semibold))
                Text(paused ? "Camera and tracking paused" : tracker.status)
                    .font(.caption).multilineTextAlignment(.center).accessibilityIdentifier("tracking-status")
                Text("Offline tracking only · tap a point to inspect")
                    .font(.caption2).foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("analysis-mode")
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
    @Binding var showTrackingStats: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Camera overlays") {
                    Toggle("Show hand joints", isOn: $tracker.showJoints)
                    Toggle("Show upper-body pose", isOn: $tracker.showPose)
                    Toggle("Show facial features", isOn: $tracker.showFace)
                    Toggle("Show joint numbers", isOn: $tracker.showNumbers)
                    Toggle("Show tracking stats", isOn: $showTrackingStats)
                    Text("Cyan: body. Yellow: face. Mint/orange: hands matched to left/right pose wrists. White: unassigned hand. Dashed lines are approximate wrist associations.")
                        .font(.footnote)
                }
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
                    Text("Facial blendshapes describe movement. Expression lab maps five cues to experimental presets; it does not infer emotion or ASL meaning. There is no sign recognition or transcription in this build.")
                    Text("Offline only: nothing is recorded or sent to a server. A rolling two-second landmark buffer lives only in memory and clears on pause, camera switch or stale capture.")
                        .accessibilityIdentifier("offline-privacy")
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
                    Text("Three detectors, same camera frame. No recording, upload or ASL transcription.").font(.footnote)
                }
            }.navigationTitle("Skeleton inspector").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }
    }
}
