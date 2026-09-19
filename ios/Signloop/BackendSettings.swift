import SwiftUI

struct BackendSettings: View {
    @ObservedObject var remote: RemoteRecognition
    @ObservedObject var tracker: CameraTracker
    @Environment(\.dismiss) private var dismiss
    @State private var label = "HELLO"
    @State private var referenceConsent = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac backend") {
                    TextField("http://your-mac.local:8787", text: $remote.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Backend access token (not the API key)", text: $remote.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Test connection") { Task { await remote.checkConnection() } }
                        .disabled(!remote.configured)
                    Text(remote.status).font(.caption)
                }
                Section("Explicit cloud sharing") {
                    Toggle("Allow gesture uploads this session", isOn: $remote.consent)
                        .disabled(!remote.configured)
                    Text("Only when you tap Analyze Gesture: the last two seconds of hand coordinates go to your Mac and then Backboard/TypeSafe. Accepted labels go to Cerebras through Backboard. No images or video are sent. Backboard may retain messages; memory-off is not a no-retention guarantee.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Camera tracking remains offline without this permission. Sharing turns off when you leave the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Capture a reference example") {
                    ZStack {
                        CameraPreview(session: tracker.session, mirrored: tracker.isFront)
                        JointOverlay(hands: tracker.hands, sourceSize: tracker.frameSize, showNumbers: false)
                    }.frame(height: 180).clipped()
                    Picker("Sign you will perform", selection: $label) {
                        ForEach(remote.vocabulary, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Keep the complete sign in camera view for two seconds, then save. The live camera continues behind this sheet. Saving replaces that label's previous example.")
                        .font(.caption)
                    Toggle("I know and performed the selected ASL sign", isOn: $referenceConsent)
                    Button(remote.busy ? "Working…" : "Save last 2 seconds as \(label)") {
                        remote.saveReference(label: label, tracker: tracker)
                    }.disabled(!remote.consent || !referenceConsent || remote.busy || !tracker.isRunning)
                    Text("Stored on your Mac. Later comparisons send references to Backboard. User-labelled examples are not independent validation. Test on a different signer before claiming accuracy.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Saved: \(remote.references.isEmpty ? "none" : remote.references.joined(separator: ", "))")
                        .font(.caption)
                    Button("Delete all saved references", role: .destructive) { confirmDelete = true }
                        .disabled(remote.busy || remote.references.isEmpty)
                }
                Section("Experimental, manually segmented") {
                    Text("Perform one sign, then tap Analyze Gesture on the camera screen. Unsupported or uncertain gestures should return Unknown. Jev scores are not calibrated confidence. Lower your hands before deliberately repeating the same sign.")
                    Text("The five-sign vocabulary is a test set, not a validated recognizer. Face/body context is missing. Captions may only re-punctuate the recognized label meanings, never invent a sentence.")
                }.font(.caption)
            }
            .navigationTitle("Backend")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all reference examples from the Mac?", isPresented: $confirmDelete) {
                Button("Delete references", role: .destructive) { Task { await remote.deleteReferences() } }
            }
        }
    }
}
