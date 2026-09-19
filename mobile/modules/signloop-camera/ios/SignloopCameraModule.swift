import ExpoModulesCore

public final class SignloopCameraModule: Module {
    public func definition() -> ModuleDefinition {
        Name("SignloopCamera")
        View(SignloopCameraView.self) {
            Events("onStatus")
            Prop("active") { (view, active: Bool) in view.active = active }
            Prop("captureId") { (view, captureId: Int) in view.captureId = captureId }
            Prop("showSkeleton") { (view, show: Bool) in view.showSkeleton = show }
            OnViewDidUpdateProps { (view: SignloopCameraView) in view.synchronize() }

            // Pull the bounded native buffer at the recognizer's cadence. No video crosses JS.
            AsyncFunction("getRecentFrames") { (view: SignloopCameraView, promise: Promise) in
                let captureId = view.captureId
                Task { @MainActor in
                    let frames = await view.tracker.recentFrames()
                    guard view.isCapturing, view.captureId == captureId else {
                        promise.resolve(["captureId": captureId, "frames": []] as [String: Any])
                        return
                    }
                    do {
                        let data = try JSONEncoder().encode(frames)
                        let json = try JSONSerialization.jsonObject(with: data)
                        promise.resolve(["captureId": captureId, "frames": json])
                    } catch { promise.reject("ERR_CAMERA_FRAMES", error.localizedDescription) }
                }
            }.runOnQueue(.main)
        }
    }
}
