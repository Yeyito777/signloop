import Foundation

@main struct SkeletonTests {
    static func main() throws {
        func p(_ id: Int, _ x: Float, _ y: Float, visibility: Float? = nil) -> SkeletonPoint {
            SkeletonPoint(id: id, x: x, y: y, z: 0, visibility: visibility)
        }
        func hand(_ x: Float, _ y: Float) -> SkeletonHand {
            SkeletonHand(points: [p(0, x, y)], modelHandedness: "Deliberately wrong", handednessScore: 1)
        }
        func frame(_ time: Int, hands: [SkeletonHand] = []) -> SkeletonFrame {
            SkeletonFrame(timestampMS: time, width: 1000, height: 1000, camera: "front", hands: hands,
                pose: [p(15, 0.2, 0.5), p(16, 0.8, 0.5)],
                face: [], expressions: [:], timingsMS: [:])
        }
        var f = frame(1, hands: [hand(0.21, 0.5), hand(0.79, 0.5)])
        f.associateHands()
        assert(f.hands.map(\.poseSide) == ["Left", "Right"])
        f.hands.reverse()
        f.associateHands()
        assert(f.hands.map(\.poseSide) == ["Right", "Left"], "Association must ignore hand ordering")
        assert(f.point(SkeletonProbe(part: "Left", id: 0))?.x == 0.21)
        assert(f.point(SkeletonProbe(part: "face", id: 10)) == nil)
        var ambiguous = frame(2, hands: [hand(0.5, 0.5)])
        ambiguous.associateHands()
        assert(ambiguous.hands[0].poseSide == nil)
        var far = frame(3, hands: [hand(0.1, 0.1)])
        far.associateHands()
        assert(far.hands[0].poseSide == nil)
        var mixed = frame(4, hands: [hand(0.2, 0.51), hand(0.8, 0.01)])
        mixed.associateHands()
        assert(mixed.hands.map(\.poseSide) == ["Left", nil], "Bad hand must not steal a good wrist")
        var missing = SkeletonFrame(timestampMS: 5, width: 1000, height: 1000, camera: "back",
            hands: [hand(0.2, 0.5)], pose: [p(15, 0.2, 0.5, visibility: 0.1)], face: [], expressions: [:], timingsMS: [:])
        missing.associateHands()
        assert(missing.hands[0].poseSide == nil)
        assert(!p(0, .nan, 0).usable && !p(0, 0.1, 0.1, visibility: .nan).usable)

        let a = SkeletonGeometry.project(p(0, 0.2, 0.4), width: 720, height: 1280,
            viewWidth: 390, viewHeight: 844, mirrored: false)
        let b = SkeletonGeometry.project(p(0, 0.2, 0.4), width: 720, height: 1280,
            viewWidth: 390, viewHeight: 844, mirrored: true)
        assert(abs(a.0+b.0-390) < 0.0001 && a.1 == b.1, "Mirror exactly once, after aspect-fill")
        let c = SkeletonGeometry.project(p(0, 0.5, 0.5), width: 720, height: 1280,
            viewWidth: 390, viewHeight: 844, mirrored: true)
        assert(abs(c.0-195) < 0.0001 && abs(c.1-422) < 0.0001)

        var buffer = SkeletonBuffer()
        for i in 0..<200 { buffer.append(frame(i*10)) }
        assert(buffer.frames.count == 60)
        buffer.append(frame(1990)) // duplicate
        buffer.append(frame(10)) // old
        assert(buffer.frames.count == 60 && buffer.frames.last?.timestampMS == 1990)
        buffer.append(frame(5000))
        assert(buffer.frames.count == 1)
        buffer.reset()
        assert(buffer.frames.isEmpty)
        let decoded = try JSONDecoder().decode(SkeletonFrame.self, from: JSONEncoder().encode(f))
        assert(decoded.timestampMS == f.timestampMS && decoded.hands[0].poseSide == "Right")
        assert(decoded.face.isEmpty && decoded.expressions.isEmpty)
        print("PASS: skeleton geometry, mirror/aspect-fill, association/rejection, missing data, RAM bounds and schema roundtrip")
    }
}
