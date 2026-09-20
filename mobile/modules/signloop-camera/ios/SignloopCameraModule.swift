import ExpoModulesCore

public final class SignloopCameraModule: Module {
    public func definition() -> ModuleDefinition {
        Name("SignloopCamera")
        // Completed gestures and ranked choices require a rebuilt native binary.
        Constant("recognitionVersion") { 3 }
        View(SignloopCameraView.self) {
            Events("onStatus", "onPrediction")
            Prop("active") { (view, active: Bool) in view.active = active }
            Prop("captureId") { (view, captureId: Int) in view.captureId = captureId }
            Prop("showSkeleton") { (view, show: Bool) in view.showSkeleton = show }
            OnViewDidUpdateProps { (view: SignloopCameraView) in view.synchronize() }
        }
    }
}
