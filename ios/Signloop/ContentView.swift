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
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                    if tracker.showJoints && tracker.isRunning && !paused {
                        JointOverlay(hands: tracker.hands, sourceSize: tracker.frameSize, showNumbers: false)
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
            if running && !paused && scenePhase == .active { recognition.start(tracker: tracker) }
            else { recognition.stop() }
        }
        .onChange(of: tracker.hands.count) { _, count in recognition.trackingChanged(hasHands: count > 0) }
        .onChange(of: tracker.isFront) { _, _ in recognition.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !paused {
                tracker.start()
                if tracker.isRunning { recognition.start(tracker: tracker) }
            } else {
                recognition.stop()
                tracker.pause()
            }
        }
        .onReceive(clock) { _ in recognition.expireResult() }
        .onDisappear { recognition.stop(); tracker.pause() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("signloop").font(.title2.weight(.semibold)).tracking(-0.6)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(recognition.live ? CameraTheme.primary : .gray).frame(width: 6, height: 6)
                Text(paused ? "PAUSED" : "LIVE").font(.caption.weight(.bold)).tracking(1)
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }

    private var liveSign: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("CURRENT SIGN").font(.caption.weight(.semibold)).tracking(2)
                    .foregroundStyle(CameraTheme.primary)
                Text(paused ? "Paused" : recognition.currentSign)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(2).multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Current possible sign: \(recognition.currentSign)")
                Text(recognition.status).font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Text("Experimental · landmarks analyzed in the cloud")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
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
                Button { tracker.showJoints.toggle() } label: {
                    Image(systemName: tracker.showJoints ? "hand.draw.fill" : "hand.draw")
                        .font(.system(size: 22)).frame(width: 56, height: 56)
                        .background(CameraTheme.container, in: Circle())
                }.accessibilityLabel("Toggle hand skeleton")
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
