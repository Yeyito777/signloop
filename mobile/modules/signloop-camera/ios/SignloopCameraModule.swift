import ExpoModulesCore

public final class SignloopCameraModule: Module {
    public func definition() -> ModuleDefinition {
        Name("SignloopCamera")
        View(SignloopCameraView.self) {
            Events("onStatus", "onSign", "onDetection", "onClose")
            Prop("active") { (view, active: Bool) in view.active = active }
            Prop("captureId") { (view, captureId: Int) in view.captureId = captureId }
            Prop("showSkeleton") { (view, show: Bool) in view.showSkeleton = show }
            Prop("showPose") { (view, show: Bool) in view.showPose = show }
            Prop("trackFace") { (view, enabled: Bool) in view.trackFace = enabled }
            Prop("labMode") { (view, enabled: Bool) in view.labMode = enabled }
            Prop("recognitionMode") { (view, mode: String) in view.recognitionMode = mode == "spelling" ? "spelling" : "signs" }
            OnViewDidUpdateProps { (view: SignloopCameraView) in view.synchronize() }

            // No automatic landmark export or second server-side recognizer.
        }
    }
}
