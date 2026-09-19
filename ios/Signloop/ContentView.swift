import SwiftUI

private let accent = Color(red: 0.73, green: 0.98, blue: 0.36)
private let surface = Color(red: 0.075, green: 0.09, blue: 0.085)

struct ContentView: View {
    @StateObject private var tracker = CameraTracker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var userPaused = false
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 16) {
            header
            camera
            metrics
            captions
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color(red: 0.035, green: 0.047, blue: 0.039).ignoresSafeArea())
        .onAppear { tracker.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !userPaused { tracker.start() }
            else if phase != .active { tracker.pause() }
        }
        .sheet(isPresented: $showInfo) { info }
        .sheet(isPresented: Binding(get: { tracker.snapshotURL != nil },
                                    set: { if !$0 { tracker.clearExport() } })) {
            if let url = tracker.snapshotURL { ShareSheet(items: [url]) }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 24)).foregroundStyle(accent)
                Text("signloop").font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-1)
            }
            Spacer()
            Text("DEV  /  01").font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1).foregroundStyle(accent)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(accent.opacity(0.1), in: Capsule())
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(.gray)
                    .frame(width: 32, height: 44)
            }.accessibilityLabel("About this prototype")
        }
    }

    private var camera: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                if tracker.showJoints {
                    JointOverlay(hands: tracker.hands, sourceSize: tracker.frameSize, showNumbers: tracker.showNumbers)
                }
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                VStack {
                    HStack(spacing: 7) {
                        Circle().fill(tracker.isRunning ? accent : .gray).frame(width: 6, height: 6)
                        Text(tracker.isRunning ? "LIVE CAMERA" : "CAMERA")
                            .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                        Spacer()
                        Image(systemName: "lock.shield")
                        Text("ON DEVICE").font(.system(size: 9, weight: .medium, design: .monospaced))
                    }.foregroundStyle(.white).padding(16)
                    Spacer()
                    if tracker.permissionDenied {
                        messagePanel(icon: "camera.fill", title: "Let your hands speak",
                                     subtitle: "Allow camera access to see your hand joints live.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        Spacer()
                    } else if let error = tracker.errorMessage {
                        messagePanel(icon: "exclamationmark.triangle", title: "Tracking unavailable", subtitle: error)
                        Button("Retry") { tracker.start() }.buttonStyle(.borderedProminent).tint(accent)
                        Spacer()
                    } else if !tracker.isRunning {
                        messagePanel(icon: "pause.circle", title: userPaused ? "Take a breath" : "Getting ready",
                                     subtitle: userPaused ? "Resume whenever you're ready." : "Preparing the camera and hand model.")
                        Spacer()
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tracker.status).font(.system(size: 17, weight: .semibold))
                            Text(tracker.hands.isEmpty ? "Bring one or both hands into view" : "21 joints per hand · movement tracked")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        Button { tracker.flipCamera() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 18)).frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }.foregroundStyle(.white).accessibilityLabel("Switch camera")
                            .disabled(!tracker.isRunning)
                    }.padding(16)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.1), lineWidth: 1))
        }
        .frame(minHeight: 220)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric("\(tracker.hands.count)/2", label: "HANDS")
            divider
            metric("\(tracker.hands.reduce(0) { $0 + $1.joints.count })", label: "JOINTS")
            divider
            metric("\(tracker.fps)", label: "TRACK FPS")
            divider
            metric("\(tracker.latencyMS)", label: "MODEL MS")
        }
        .padding(.vertical, 13)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE TRANSCRIPT").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                Spacer()
                Text("NOT CONNECTED").font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.gray).padding(5).overlay(Capsule().stroke(.gray.opacity(0.3)))
            }.foregroundStyle(accent)
            Text("First, we see your hands.")
                .font(.system(size: 20, weight: .medium))
            Text("Hand tracking is live. Sign recognition and English captions are not enabled yet.")
                .font(.system(size: 12)).foregroundStyle(.gray).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack {
                Text("RAW SIGNS  —")
                Spacer()
                Text("\(tracker.bufferedFrames) FRAMES / 2s")
            }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.gray)
        }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                userPaused.toggle()
                if userPaused { tracker.pause() } else { tracker.start() }
            } label: {
                Label(userPaused ? "Resume" : "Pause", systemImage: userPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(accent, in: Capsule()).foregroundStyle(.black)
            }
            Button { tracker.showJoints.toggle() } label: {
                Image(systemName: tracker.showJoints ? "hand.draw.fill" : "hand.draw")
                    .frame(width: 46, height: 46)
                    .background(tracker.showJoints ? accent.opacity(0.12) : surface, in: Circle())
                    .foregroundStyle(tracker.showJoints ? accent : .gray)
            }.accessibilityLabel(tracker.showJoints ? "Hide joint overlay" : "Show joint overlay")
            Button { tracker.showNumbers.toggle() } label: {
                Image(systemName: "number").frame(width: 46, height: 46)
                    .background(tracker.showNumbers ? accent.opacity(0.12) : surface, in: Circle())
                    .foregroundStyle(tracker.showNumbers ? accent : .gray)
            }.accessibilityLabel("Toggle landmark indices")
            Button { tracker.exportLandmarks() } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 46, height: 46)
                    .background(surface, in: Circle()).foregroundStyle(.white)
            }.accessibilityLabel("Export recent landmark JSON").disabled(tracker.bufferedFrames == 0)
        }
    }

    private var info: some View {
        NavigationStack {
            List {
                Section("Developer MVP") {
                    Text("Real Google MediaPipe hand tracking, entirely on this iPhone. Up to two hands, with 21 landmarks each.")
                    Text("Mint = left hand. Orange = right hand. White dots = fingertips. Front-camera video and landmarks are mirrored together.")
                    Text("Use the # button for joint indices. The share button exports the last two seconds of landmark coordinates as JSON—not video.")
                }
                Section("Not translation yet") {
                    Text("No signs or English sentences are recognized in this build. The classifier stub always returns unknown. No Jev, Backboard or Cerebras requests are made.")
                    Text("Hand landmarks alone cannot capture full ASL. Face, body, context and temporal validation are required.")
                }
                Section("Privacy") {
                    Text("Camera frames are processed locally and discarded. A two-second landmark buffer stays in memory unless you explicitly export it. No camera footage is recorded.")
                }
                Section("Try it") {
                    Text("Use good lighting. Keep your whole hand in frame, spread your fingers, then try both hands, turning your palm and moving slowly. Check the overlay with both cameras.")
                }
            }
            .navigationTitle("Inside signloop")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInfo = false } } }
        }.tint(accent)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 26) }

    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 21, weight: .medium, design: .monospaced)).foregroundStyle(.white)
            Text(label).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.gray)
        }.frame(maxWidth: .infinity)
    }

    private func messagePanel(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(accent)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
