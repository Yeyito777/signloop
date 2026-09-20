import ExpoModulesCore

public final class SignloopCameraModule: Module {
    public func definition() -> ModuleDefinition {
        Name("SignloopCamera")
        // Predictions include a time-aligned expression; live expressions have their own event.
        Constant("recognitionVersion") { 5 }
        View(SignloopCameraView.self) {
            Events("onStatus", "onPrediction", "onExpression")
            Prop("active") { (view, active: Bool) in view.active = active }
            Prop("captureId") { (view, captureId: Int) in view.captureId = captureId }
            Prop("showSkeleton") { (view, show: Bool) in view.showSkeleton = show }
            OnViewDidUpdateProps { (view: SignloopCameraView) in view.synchronize() }
        }
    }
}
