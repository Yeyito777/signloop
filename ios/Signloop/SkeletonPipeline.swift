import Foundation
import MediaPipeTasksVision
import QuartzCore

/// Queue-confined. All three tasks consume the SAME image and capture timestamp.
/// No classifier, language model, server, recordings or cross-frame fusion.
final class SkeletonPipeline {
    private let hand: HandLandmarker
    private let pose: PoseLandmarker
    private let face: FaceLandmarker?

    init(trackFace: Bool = true) throws {
        func model(_ name: String) throws -> String {
            guard let path = Bundle.main.path(forResource: name, ofType: "task") else {
                throw NSError(domain: "Signloop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing \(name). Run ios/scripts/bootstrap.sh and rebuild."])
            }
            return path
        }
        let h = HandLandmarkerOptions()
        h.baseOptions.modelAssetPath = try model("hand_landmarker")
        h.runningMode = .video
        h.numHands = 2
        h.minHandDetectionConfidence = 0.55
        h.minHandPresenceConfidence = 0.55
        h.minTrackingConfidence = 0.55
        hand = try HandLandmarker(options: h)

        let p = PoseLandmarkerOptions()
        p.baseOptions.modelAssetPath = try model("pose_landmarker_lite")
        p.runningMode = .video
        p.numPoses = 1
        p.minPoseDetectionConfidence = 0.5
        p.minPosePresenceConfidence = 0.5
        p.minTrackingConfidence = 0.5
        p.shouldOutputSegmentationMasks = false
        pose = try PoseLandmarker(options: p)

        if trackFace {
            let f = FaceLandmarkerOptions()
            f.baseOptions.modelAssetPath = try model("face_landmarker")
            f.runningMode = .video
            f.numFaces = 1
            f.minFaceDetectionConfidence = 0.5
            f.minFacePresenceConfidence = 0.5
            f.minTrackingConfidence = 0.5
            f.outputFaceBlendshapes = true
            face = try FaceLandmarker(options: f)
        } else { face = nil }
    }

    func detect(_ image: MPImage, timestampMS: Int, width: Int, height: Int,
                camera: String) throws -> SkeletonFrame {
        let start = CACurrentMediaTime()
        let h = try hand.detect(videoFrame: image, timestampInMilliseconds: timestampMS)
        let afterHand = CACurrentMediaTime()
        let p = try pose.detect(videoFrame: image, timestampInMilliseconds: timestampMS)
        let afterPose = CACurrentMediaTime()
        let f = try face?.detect(videoFrame: image, timestampInMilliseconds: timestampMS)
        let end = CACurrentMediaTime()
        func points(_ landmarks: [NormalizedLandmark]) -> [SkeletonPoint] {
            landmarks.enumerated().compactMap { i, l in
                guard l.x.isFinite, l.y.isFinite, l.z.isFinite else { return nil }
                return SkeletonPoint(id: i, x: l.x, y: l.y, z: l.z,
                                     visibility: l.visibility?.floatValue, presence: l.presence?.floatValue)
            }
        }
        let hands = h.landmarks.enumerated().map { i, landmarks in
            let category = h.handedness.indices.contains(i) ? h.handedness[i].first : nil
            return SkeletonHand(points: points(landmarks),
                                modelHandedness: category?.categoryName ?? "Unknown",
                                handednessScore: category?.score ?? 0)
        }
        var expressions: [String: Float] = [:]
        for c in f?.faceBlendshapes.first?.categories ?? [] {
            if let name = c.categoryName, c.score.isFinite { expressions[name] = max(0, min(1, c.score)) }
        }
        var result = SkeletonFrame(timestampMS: timestampMS, width: width, height: height, camera: camera,
            hands: hands, pose: points(p.landmarks.first ?? []).filter { $0.id <= 24 },
            face: points(f?.faceLandmarks.first ?? []), expressions: expressions,
            timingsMS: ["hands": (afterHand-start)*1000, "pose": (afterPose-afterHand)*1000,
                        "face": face == nil ? 0 : (end-afterPose)*1000, "total": (end-start)*1000])
        result.associateHands()
        return result
    }
}
