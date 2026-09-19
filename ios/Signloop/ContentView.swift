import SwiftUI

private enum CameraTheme {
    static let primary = Color(red: 0.78, green: 0.91, blue: 0.62)
    static let onPrimary = Color(red: 0.12, green: 0.19, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.11, blue: 0.09)
    static let container = Color(red: 0.18, green: 0.21, blue: 0.17)
}

/// One screen. Opening the camera starts live landmark inference automatically.
struct ContentView: View {
    @StateObject private var tracker = CameraTracker()
    @StateObject private var recognition = RemoteRecognition()
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false
    @State private var showSettings = false
    @AppStorage("showTrackingStats") private var showTrackingStats = false
    @AppStorage("cloudRecognitionEnabled") private var cloudRecognitionEnabled = false
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                    if tracker.showJoints && tracker.isRunning && !paused {
                        JointOverlay(hands: tracker.hands, sourceSize: tracker.frameSize, showNumbers: tracker.showNumbers)
                    }
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.6), location: 0),
                        .init(color: .clear, location: 0.25),
                        .init(color: .clear, location: 0.5),
                        .init(color: .black.opacity(0.85), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    if paused { Color.black.opacity(0.55) }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }.ignoresSafeArea()
            if tracker.permissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("Let your hands speak").font(.title2.bold())
                    Button("Allow camera in Settings") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }.buttonStyle(.borderedProminent)
                }.padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            } else if tracker.errorMessage != nil {
                Button("Camera unavailable · tap to retry") { tracker.start() }
                    .padding().background(.ultraThinMaterial, in: Capsule())
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { liveSign }
        .background(Color.black)
        .foregroundStyle(.white)
        .tint(CameraTheme.primary)
        .onAppear { tracker.start() }
        .onChange(of: tracker.isRunning) { _, running in
            if running && !paused && scenePhase == .active && cloudRecognitionEnabled { recognition.start(tracker: tracker) }
            else { recognition.stop() }
        }
        .onChange(of: cloudRecognitionEnabled) { _, enabled in
            if enabled && tracker.isRunning && !paused && scenePhase == .active {
                recognition.start(tracker: tracker)
            } else { recognition.stop() }
        }
        .onChange(of: tracker.hands.count) { _, count in recognition.trackingChanged(hasHands: count > 0) }
        .onChange(of: tracker.isFront) { _, _ in recognition.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !paused {
                tracker.start()
                if tracker.isRunning && cloudRecognitionEnabled { recognition.start(tracker: tracker) }
            } else {
                recognition.stop()
                tracker.pause()
            }
        }
        .onReceive(clock) { _ in recognition.expireResult(); tracker.expireLocalResult() }
        .onDisappear { recognition.stop(); tracker.pause() }
        .sheet(isPresented: $showSettings) {
            CameraSettings(tracker: tracker, recognition: recognition, showTrackingStats: $showTrackingStats,
                           cloudRecognitionEnabled: $cloudRecognitionEnabled)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var displayedSign: String {
        if paused { return "Paused" }
        if tracker.permissionDenied { return "Camera access needed" }
        if tracker.errorMessage != nil { return "Camera unavailable" }
        if !tracker.isRunning { return "Starting…" }
        if tracker.localSign == "I_LOVE_YOU" { return "I love you" }
        if tracker.hands.isEmpty { return "No hands" }
        return cloudRecognitionEnabled ? recognition.currentSign : "Unknown"
    }

    private var displayedStatus: String {
        if paused { return "Camera and recognition paused" }
        if tracker.permissionDenied { return "Enable Camera in Settings to continue" }
        if tracker.errorMessage != nil { return "Tap the camera message to retry" }
        if tracker.localSign != nil { return "Possible ILY handshape · on-device" }
        if cloudRecognitionEnabled { return recognition.status }
        return "Try ILY: thumb, index and pinky extended"
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("signloop").font(.title2.weight(.semibold)).tracking(-0.6)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 21))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }.accessibilityLabel("Settings")
                    .accessibilityIdentifier("camera-settings")
            }
            if showTrackingStats {
                HStack(spacing: 14) {
                    Label("\(tracker.hands.count) hands", systemImage: "hand.raised")
                    Text("\(tracker.fps) FPS")
                    Text("\(tracker.latencyMS) ms tracking")
                    Spacer(minLength: 0)
                }.font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(10).background(.ultraThinMaterial, in: Capsule())
                    .accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }

    private var liveSign: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("CURRENT SIGN").font(.caption.weight(.semibold)).tracking(2)
                    .foregroundStyle(CameraTheme.primary)
                Text(displayedSign)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(2).multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Current possible sign: \(displayedSign)")
                    .accessibilityIdentifier("current-sign")
                Text(displayedStatus).font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    .accessibilityIdentifier("recognition-status")
                Text(cloudRecognitionEnabled ? "Experimental · local + cloud analysis" : "Offline preview · ILY handshape only")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .accessibilityIdentifier("analysis-mode")
            }.frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
                .background(CameraTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
            HStack(spacing: 12) {
                Button {
                    paused.toggle()
                    if paused { recognition.stop(); tracker.pause() }
                    else { tracker.start() }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 56)
                        .foregroundStyle(CameraTheme.onPrimary)
                        .background(CameraTheme.primary, in: Capsule())
                }
                .accessibilityIdentifier("pause-resume")
                Button { recognition.invalidate(); tracker.flipCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22)).frame(width: 56, height: 56)
                        .background(CameraTheme.container, in: Circle())
                }.disabled(!tracker.isRunning || paused).accessibilityLabel("Switch camera")
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }
}

private struct CameraSettings: View {
    @ObservedObject var tracker: CameraTracker
    @ObservedObject var recognition: RemoteRecognition
    @Binding var showTrackingStats: Bool
    @Binding var cloudRecognitionEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show hand joints", isOn: $tracker.showJoints)
                    Toggle("Show joint numbers", isOn: $tracker.showNumbers)
                        .disabled(!tracker.showJoints)
                    Toggle("Show tracking stats", isOn: $showTrackingStats)
                } header: {
                    Text("Camera overlays")
                } footer: {
                    Text("Mint is the left hand; orange is the right. White dots mark fingertips. These settings are remembered.")
                }
                Section("Tracking") {
                    LabeledContent("Hands", value: "\(tracker.hands.count) / 2")
                    LabeledContent("Joints", value: "\(tracker.hands.reduce(0) { $0 + $1.joints.count })")
                    LabeledContent("Tracking rate", value: "\(tracker.fps) FPS")
                    LabeledContent("On-device tracking", value: "\(tracker.latencyMS) ms")
                    LabeledContent("Last sign request", value: recognition.latencyMS > 0 ? "\(recognition.latencyMS) ms" : "—")
                }
                Section("Live sign estimates") {
                    Toggle("Experimental cloud signs", isOn: $cloudRecognitionEnabled)
                    Text("The ILY handshape is recognized on your iPhone. Hold one hand in view: thumb, index and pinky extended; middle and ring folded. No Mac, network, recording or setup is needed.")
                    Text("Other signs are not supported locally yet. Thumbs-up is not treated as ASL YES, and an open palm is not treated as HELLO.")
                    Text(cloudRecognitionEnabled
                         ? "Hand coordinates are sent to the configured backend and model provider. This needs a working backend/network. No camera images or video are sent; Pause stops new requests."
                         : "Cloud analysis is off. Camera images and hand coordinates stay on your iPhone.")
                    Text("Limited gesture preview, not validated ASL translation. Faces and body context are not tracked.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                }
            }
        }.tint(CameraTheme.primary)
    }
}
