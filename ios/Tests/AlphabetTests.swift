import Foundation

@main struct AlphabetTests {
    struct Fixture: Decodable {
        struct Row: Decodable { let label: String; let raw: [Double]; let normalized: [Float]; let scores: [Float] }
        let rows: [Row]
    }
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ text: String) {
            precondition(value(), text); count += 1
        }
        let args = CommandLine.arguments
        let model = try JSONDecoder().decode(AlphabetModel.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        try model.validate()
        check(model.labels.count == 24 && !model.labels.contains("J") && !model.labels.contains("Z"), "No fake motion letters")
        check(AlphabetModel.aurelioLetters == ["A","U","R","E","L","I","O"], "Exactly Aurelio's letters")
        let zero = [Float](repeating: 0, count: 86)
        check(model.prediction(normalized: zero, allowedLetters: []) == nil, "Empty whitelist fails closed")
        check(model.prediction(normalized: zero, allowedLetters: ["A","A"]) == nil, "Duplicate whitelist rejected")
        check(model.prediction(normalized: zero, allowedLetters: ["J"]) == nil, "Unavailable letter rejected")
        // Synthetic logits deliberately make excluded C huge. Masking after
        // softmax would underflow both O and A to zero and lose their ordering.
        var layers = model.layers
        let last = layers.removeLast()
        var bias = [Float](repeating: -10, count: last.output)
        bias[model.labels.firstIndex(of: "C")!] = 10000
        bias[model.labels.firstIndex(of: "O")!] = 2000
        bias[model.labels.firstIndex(of: "A")!] = 1999
        layers.append(AlphabetModel.Layer(input: last.input, output: last.output,
            weights: [Float](repeating: 0, count: last.weights.count), bias: bias,
            relu: false, scale: [Float](repeating: 1, count: last.output),
            offset: [Float](repeating: 0, count: last.output)))
        let synthetic = AlphabetModel(version: model.version, labels: model.labels, mean: model.mean,
                                      std: model.std, layers: layers, sourceRevision: model.sourceRevision)
        check(synthetic.prediction(normalized: zero, allowedLetters: model.labels) == "C", "Unrestricted synthetic winner")
        check(synthetic.prediction(normalized: zero, allowedLetters: AlphabetModel.aurelioLetters) == "O",
              "Excluded winner cannot compete or underflow the active ranking")
        check(AlphabetModel.features([]) == nil, "Invalid input rejected")
        check(AlphabetModel.features([Double](repeating: .nan,count: 63)) == nil, "NaN rejected")
        check(model.scores(normalized: []) == nil, "Wrong input size rejected")
        let blank = SkeletonFrame(timestampMS: 0,width: 720,height: 1280,camera: "synthetic",
                                  hands: [],pose: [],face: [],expressions: [:],timingsMS: [:])
        check(AlphabetModel.input(blank,mirror: true) == nil, "Empty frame not a letter")
        var draft = SpellingDraft()
        for l in ["A","U","R","E","L","I","O"] { draft.append(l) }
        check(draft.text == "AURELIO", "Explicit spelling retains name")
        draft.append("O")
        check(draft.text == "AURELIOO", "Repeated letters require independent confirmation, not deduplication")
        draft.backspace()
        draft.append("WRONG")
        check(draft.text == "AURELIO", "Only individual letters accepted")
        draft.append("J"); draft.append("Z")
        check(draft.text.hasSuffix("JZ"), "Explicit manual J/Z allowed")
        draft.clear(); draft.backspace()
        check(draft.text.isEmpty, "Safe deletion and clear")
        for _ in 0..<50 { draft.append("A") }
        check(draft.text.count == 40, "Bounded RAM-only draft")
        var nameDraft = SpellingDraft(allowedLetters: AlphabetModel.aurelioLetters)
        for letter in AlphabetModel.aurelioLetters { nameDraft.append(letter) }
        for letter in ["C","P","J","Z","B"," ","WRONG"] { nameDraft.append(letter) }
        check(nameDraft.text == "AURELIO", "Name draft rejects every excluded/manual letter")
        if args.count > 2 {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            var correct = 0, parity = 0, nameCorrect = 0, nameTotal = 0
            var maximum: Float = 0
            let start = Date()
            for row in fixture.rows {
                let features = model.normalized(row.raw)!
                check(zip(features,row.normalized).allSatisfy { abs($0-$1) < 0.0001 }, "Python/Swift feature parity")
                let scores = model.scores(normalized: features)!
                let error = zip(scores,row.scores).map { abs($0-$1) }.max()!
                maximum = max(maximum,error)
                check(error < 0.0001, "Python/Swift full MLP score parity")
                let top = scores.indices.max { scores[$0] < scores[$1] }!
                let expected = row.scores.indices.max { row.scores[$0] < row.scores[$1] }!
                parity += top == expected ? 1 : 0
                correct += model.labels[top] == row.label ? 1 : 0
                let restricted = model.prediction(normalized: features, allowedLetters: AlphabetModel.aurelioLetters)
                check(AlphabetModel.aurelioLetters.contains(restricted ?? ""), "No removed letters on any real source sample")
                if AlphabetModel.aurelioLetters.contains(row.label) {
                    nameTotal += 1
                    nameCorrect += restricted == row.label ? 1 : 0
                }
            }
            print("Upstream reused samples: \(correct)/\(fixture.rows.count) correct, \(parity) identical top1, max error \(maximum), total \(-start.timeIntervalSinceNow*1000)ms. Not live/held-out-signer accuracy.")
            print("AURELIO restricted source samples: \(nameCorrect)/\(nameTotal); not live accuracy or unknown rejection.")
            func wait(_ condition: () -> Bool) {
                let deadline = Date().addingTimeInterval(3)
                while !condition() && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                check(condition(), "Async alphabet operation completed within test deadline")
            }
            let live = AlphabetRecognition(modelURL: URL(fileURLWithPath: args[1]))
            live.mirrorInput = false
            live.load()
            wait { live.ready }
            let row = fixture.rows[0]
            let points = (0..<21).map { i in SkeletonPoint(id: i,
                x: Float(row.raw[i*3]), y: Float(row.raw[i*3+1]), z: Float(row.raw[i*3+2])) }
            let hand = SkeletonHand(points: points, modelHandedness: "Unknown", handednessScore: 0)
            func frame(_ time: Int, _ hands: [SkeletonHand]) -> SkeletonFrame {
                SkeletonFrame(timestampMS: time, width: 720, height: 1280, camera: "replay",
                              hands: hands, pose: [], face: [], expressions: [:], timingsMS: [:])
            }
            live.receive(frame(1000,[hand]))
            wait { live.detail == "Hold the letter briefly" }
            check(live.letter == nil, "Single observation does not become an appended letter")
            live.receive(frame(1133,[hand]))
            wait { live.letter != nil }
            let raw = AlphabetModel.input(frame(1133,[hand]),mirror: false)!
            let expected = model.scores(normalized: model.normalized(raw)!)!
            check(live.letter == model.labels[expected.indices.max { expected[$0] < expected[$1] }!],
                  "Actual live adapter agrees with native model")
            live.receive(frame(1266,[]))
            check(live.letter == nil, "Hand loss clears letter immediately")
            live.receive(frame(1400,[hand,hand]))
            check(live.letter == nil, "Two-hand ambiguity is not guessed")
            live.receive(frame(1533,[hand]))
            live.reset()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            check(live.letter == nil, "Reset invalidates in-flight letter result")
            let nameLive = AlphabetRecognition(modelURL: URL(fileURLWithPath: args[1]),
                                               allowedLetters: AlphabetModel.aurelioLetters)
            nameLive.load()
            wait { nameLive.ready }
            nameLive.receive(frame(2000,[hand]))
            wait { nameLive.detail == "Hold the letter briefly" }
            nameLive.receive(frame(2133,[hand]))
            wait { nameLive.letter != nil }
            check(nameLive.letter == model.prediction(normalized: model.normalized(raw)!,
                                                     allowedLetters: AlphabetModel.aurelioLetters),
                  "Actual restricted async adapter selects only active logits")
            nameLive.receive(frame(2266,[]))
            check(nameLive.letter == nil, "Hand loss clears restricted letter")
        }
        print("PASS: \(count) alphabet and explicit spelling checks")
    }
}
