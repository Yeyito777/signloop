import Foundation
import Accelerate
import Combine

/// Native MLP trained on Siruyy/realtime-asl-recognizer's MIT coordinates,
/// with a port of its 86-channel feature extractor.
/// See Resources/alphabet-license.txt. Scores are uncalibrated model outputs.
/// No J/Z fiction: those require temporal training and are manual entry only.
struct AlphabetModel: Codable {
    struct Layer: Codable {
        let input: Int
        let output: Int
        let weights: [Float]
        let bias: [Float]
        let relu: Bool
        let scale: [Float]
        let offset: [Float]
    }
    static let letters = Array("ABCDEFGHIKLMNOPQRSTUVWXY").map(String.init)
    static let aurelioLetters = Array("AURELIO").map(String.init)
    let version: Int
    let labels: [String]
    let mean: [Double]
    let std: [Double]
    let layers: [Layer]
    let sourceRevision: String

    func validate() throws {
        let sizes = [86, 256, 128, 64, 32, 24]
        guard version == 1, labels == Self.letters, mean.count == 86, std.count == 86,
              mean.allSatisfy(\.isFinite), std.allSatisfy({ $0.isFinite && $0 > 0 }),
              layers.count == 5 else { throw CocoaError(.fileReadCorruptFile) }
        for (i, l) in layers.enumerated() {
            guard l.input == sizes[i], l.output == sizes[i+1],
                  l.weights.count == l.input*l.output, l.bias.count == l.output,
                  l.scale.count == l.output, l.offset.count == l.output,
                  l.relu == (i < 4),
                  [l.weights, l.bias, l.scale, l.offset].allSatisfy({ $0.allSatisfy(\.isFinite) })
            else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// Matches upstream's raw-image-coordinate feature extractor exactly.
    /// Do NOT apply the word matcher's shoulder or palm normalization here.
    static func features(_ raw: [Double]) -> [Double]? {
        guard raw.count == 63, raw.allSatisfy({ $0.isFinite && abs($0) < 10 }) else { return nil }
        let tips = [4, 8, 12, 16, 20], mcps = [2, 5, 9, 13, 17]
        func vector(_ a: Int, _ b: Int) -> [Double] { (0..<3).map { raw[a*3+$0]-raw[b*3+$0] } }
        func length(_ x: [Double]) -> Double { sqrt(x.reduce(0) { $0+$1*$1 }) }
        func distance(_ a: Int, _ b: Int) -> Double { length(vector(a,b)) }
        let palm = vector(9, 0)
        var result = raw
        result += tips.map { distance($0, 0) }
        result += (0..<4).map { distance(tips[$0], tips[$0+1]) }
        result += (0..<5).map { distance(tips[$0], mcps[$0]) }
        result += palm
        for i in 0..<5 {
            let v = vector(tips[i], mcps[i])
            let cosine = zip(v, palm).reduce(0) { $0+$1.0*$1.1 }/(length(v)*length(palm)+1e-8)
            result.append(acos(max(-1,min(1,cosine)))*180/Double.pi)
        }
        var span = 0.0
        for i in 0..<5 { for j in (i+1)..<5 { span = max(span,distance(tips[i],tips[j])) } }
        result.append(span)
        return result
    }

    func normalized(_ raw: [Double]) -> [Float]? {
        guard let values = Self.features(raw) else { return nil }
        let x = values.indices.map { Float((values[$0]-mean[$0])/std[$0]) }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    private func logits(normalized: [Float]) -> [Float]? {
        guard normalized.count == 86, normalized.allSatisfy(\.isFinite) else { return nil }
        var x = normalized
        for layer in layers {
            var y = layer.bias
            cblas_sgemv(CblasRowMajor, CblasTrans, Int32(layer.input), Int32(layer.output),
                        1, layer.weights, Int32(layer.output), x, 1, 1, &y, 1)
            for i in y.indices {
                y[i] = (layer.relu ? max(0,y[i]) : y[i])*layer.scale[i]+layer.offset[i]
            }
            x = y
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    func prediction(normalized: [Float], allowedLetters: [String]) -> String? {
        guard !allowedLetters.isEmpty, Set(allowedLetters).count == allowedLetters.count,
              Set(allowedLetters).isSubset(of: Set(labels)),
              let values = logits(normalized: normalized) else { return nil }
        // Select among active logits BEFORE softmax. An excluded C/P cannot
        // win, nor underflow the active scores to identical zeros.
        let indices = labels.indices.filter { allowedLetters.contains(labels[$0]) }
        return indices.max { values[$0] < values[$1] }.map { labels[$0] }
    }

    func scores(normalized: [Float]) -> [Float]? {
        guard var x = logits(normalized: normalized), let maximum = x.max() else { return nil }
        x = x.map { exp($0-maximum) }
        let sum = x.reduce(0,+)
        return sum.isFinite && sum > 0 ? x.map { $0/sum } : nil
    }

    static func input(_ frame: SkeletonFrame, mirror: Bool) -> [Double]? {
        // Explicit single-hand mode avoids silently switching people/hands.
        guard frame.hands.count == 1 else { return nil }
        let points = frame.hands[0].points.sorted { $0.id < $1.id }
        guard points.map(\.id) == Array(0..<21) else { return nil }
        return points.flatMap { [Double(mirror ? 1-$0.x : $0.x), Double($0.y), Double($0.z)] }
    }
}

struct SpellingDraft {
    private(set) var text = ""
    private let allowedLetters: Set<String>
    init(allowedLetters: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ ").map(String.init)) {
        self.allowedLetters = Set(allowedLetters)
    }
    mutating func append(_ letter: String) {
        guard text.count < 40, letter.count == 1, allowedLetters.contains(letter) else { return }
        text += letter
    }
    mutating func backspace() { if !text.isEmpty { text.removeLast() } }
    mutating func clear() { text = "" }
}

final class AlphabetRecognition: ObservableObject {
    let allowedLetters: [String]
    @Published private(set) var letter: String?
    @Published private(set) var ready = false
    @Published private(set) var detail = "Loading static alphabet…"
    @Published private(set) var matchMS = 0
    /// Collection scripts saved unmirrored webcam landmarks (the separate
    /// upstream preview mirrored its input). Match collection, not preview.
    @Published var mirrorInput = false { didSet { reset() } }
    private let worker = DispatchQueue(label: "com.signloop.alphabet", qos: .userInitiated)
    private var model: AlphabetModel?
    private var busy = false
    private var started = false
    private var generation = 0
    private var history: [String] = []
    private var lastTimestamp: Int?
    private var lastRequest = -1000
    private let modelURL: URL?

    init(modelURL: URL? = Bundle.main.url(forResource: "alphabet-static", withExtension: "json"),
         allowedLetters: [String] = AlphabetModel.letters) {
        self.modelURL = modelURL
        self.allowedLetters = allowedLetters
    }
    func load() {
        guard !started else { return }
        started = true
        worker.async {
            do {
                guard let url = self.modelURL else { throw CocoaError(.fileNoSuchFile) }
                let data = try Data(contentsOf: url)
                guard data.count < 3_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                let model = try JSONDecoder().decode(AlphabetModel.self, from: data)
                try model.validate()
                guard !self.allowedLetters.isEmpty,
                      Set(self.allowedLetters).count == self.allowedLetters.count,
                      Set(self.allowedLetters).isSubset(of: Set(model.labels)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                self.model = model
                DispatchQueue.main.async { self.ready = true; self.detail = "Use one hand · tap Add to keep a letter" }
            } catch {
                DispatchQueue.main.async { self.detail = "Alphabet model unavailable" }
            }
        }
    }
    func reset() {
        generation += 1
        history.removeAll()
        letter = nil
        lastTimestamp = nil
        lastRequest = -1000
        matchMS = 0
        if ready { detail = "Use one hand · tap Add to keep a letter" }
    }
    func receive(_ frame: SkeletonFrame) {
        guard ready else { return }
        if let last = lastTimestamp, frame.timestampMS <= last || frame.timestampMS-last > 300 { reset() }
        lastTimestamp = frame.timestampMS
        guard let raw = AlphabetModel.input(frame, mirror: mirrorInput) else {
            reset(); detail = "Keep exactly one hand visible"; return
        }
        guard !busy, frame.timestampMS-lastRequest >= 100 else { return }
        lastRequest = frame.timestampMS
        busy = true
        let token = generation, began = ProcessInfo.processInfo.systemUptime
        worker.async {
            let candidate = self.model?.normalized(raw).flatMap {
                self.model?.prediction(normalized: $0, allowedLetters: self.allowedLetters)
            }
            DispatchQueue.main.async {
                self.busy = false
                guard token == self.generation else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime-began
                guard elapsed < 0.4, let candidate else {
                    self.reset(); self.detail = "Letter estimate delayed"; return
                }
                self.matchMS = Int(elapsed*1000)
                self.history.append(candidate)
                if self.history.count > 3 { self.history.removeFirst() }
                // Require agreement, but don't leave a previous letter visible
                // through transitions. Never automatically write guessed letters.
                self.letter = self.history.count >= 2 && self.history.suffix(2).allSatisfy { $0 == candidate }
                    ? candidate : nil
                self.detail = self.letter == nil ? "Hold the letter briefly"
                    : "Letter guess · verify before Add"
            }
        }
    }
}
