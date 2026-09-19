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
    @StateObject private var recognition = LocalSignRecognition()
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false
    @State private var showSettings = false
    @AppStorage("showTrackingStats") private var showTrackingStats = false
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
                        .foregroundStyle(CameraTheme.onPrimary)
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
        .onAppear {
            tracker.onFrame = { [weak recognition] frame in recognition?.receive(frame) }
            tracker.onReset = { [weak recognition] in recognition?.reset() }
            recognition.prepare()
            tracker.start()
        }
        .onChange(of: tracker.isRunning) { _, running in
            recognition.setRunning(running && !paused && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !paused {
                tracker.start()
                recognition.setRunning(tracker.isRunning)
            } else {
                recognition.setRunning(false)
                tracker.pause()
            }
        }
        .onReceive(clock) { _ in recognition.expire(); tracker.expireLocalResult() }
        .onDisappear {
            recognition.setRunning(false)
            tracker.pause()
            tracker.onFrame = nil
            tracker.onReset = nil
        }
        .sheet(isPresented: $showSettings) {
            CameraSettings(tracker: tracker, recognition: recognition, showTrackingStats: $showTrackingStats)
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
        let names = ["HELLO": "Hello", "YES": "Yes", "NO": "No",
                     "PLEASE": "Please", "THANK_YOU": "Thank you"]
        return recognition.currentSign.flatMap { names[$0] } ?? "Unknown"
    }

    private var displayedStatus: String {
        if paused { return "Camera and recognition paused" }
        if tracker.permissionDenied { return "Enable Camera in Settings to continue" }
        if tracker.errorMessage != nil { return "Tap the camera message to retry" }
        if tracker.localSign != nil { return "Possible ILY handshape · on-device" }
        if recognition.available {
            if recognition.inferenceFailed { return "Local sign model error · retrying" }
            return recognition.currentSign == nil
                ? "Try hello, yes, no, please or thank you"
                : "Possible sign · processed on your iPhone"
        }
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
                Text(recognition.available ? "Offline research preview · 5 signs + ILY" : "Offline preview · ILY handshape only")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .accessibilityIdentifier("analysis-mode")
            }.frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
                .background(CameraTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28))
            HStack(spacing: 12) {
                Button {
                    paused.toggle()
                    if paused { recognition.setRunning(false); tracker.pause() }
                    else { tracker.start() }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 56)
                        .foregroundStyle(CameraTheme.onPrimary)
                        .background(CameraTheme.primary, in: Capsule())
                }
                .accessibilityIdentifier("pause-resume")
                Button { recognition.reset(); tracker.flipCamera() } label: {
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
    @ObservedObject var recognition: LocalSignRecognition
    @Binding var showTrackingStats: Bool
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
                    LabeledContent("Camera frame age", value: tracker.frameAgeMS.map { "\($0) ms" } ?? "—")
                    LabeledContent("On-device sign inference", value: recognition.latencyMS > 0 ? "\(recognition.latencyMS) ms" : "—")
                }
                Section("Live sign estimates") {
                    Text(recognition.modelStatus).accessibilityIdentifier("local-model-status")
                    if recognition.available {
                        Text("Supported: hello, yes, no, please, thank you, and the ILY handshape. Sign naturally with your hands fully in view. Estimates update automatically and uncertain input stays Unknown.")
                    }
                    Text("The ILY handshape is recognized on your iPhone. Hold one hand in view: thumb, index and pinky extended; middle and ring folded. No Mac, network, recording or setup is needed.")
                    if !recognition.available {
                        Text("The five-sign research model is not loaded in this build. Only ILY is available; there is no cloud fallback.")
                    }
                    Text("Thumbs-up is not treated as ASL YES, and an open palm is not treated as HELLO.")
                    Text("Offline only. Camera images and hand coordinates stay on your iPhone; nothing is recorded or sent to a server.")
                        .accessibilityIdentifier("offline-privacy")
                    Text("Limited research preview, not validated ASL translation. Faces and body context are not tracked.")
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
