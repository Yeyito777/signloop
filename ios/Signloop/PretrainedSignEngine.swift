import CryptoKit
import Foundation

/// Queue-confined research engine. Uses the TensorFlow Lite C runtime already
/// inside pinned MediaPipe, through Google's unchanged official Swift wrapper.
/// No network, saving, automatic download, or default camera activation.
final class PretrainedSignEngine {
    static let modelSHA = "f55a2bb1ebe6d1e912a98e31c6ef3f995c9ae261f408fe115f2008099d3f0bb7"
    static let vocabularySHA = "1fe747c2f44c68dbb396947e35193c96d363f3dede0be8defa5e08546400bf5d"
    enum Failure: Error { case unrecognizedAssets, invalidOutput, unvalidatedRuntime }
    private var interpreter: Interpreter?
    // TfLiteModelCreate borrows these bytes. The upstream Swift wrapper does
    // not retain its temporary Model after constructing an Interpreter.
    // Keep the verified immutable buffer alive until AFTER interpreter release.
    private let modelBytes: Data
    let policy: PretrainedSignPolicy
    private var frameCount: Int?
    var runtimeVersion: String { Runtime.version }

    init(model: URL, vocabulary: URL) throws {
        guard Runtime.version == "2.18.0" else { throw Failure.unvalidatedRuntime }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard try model.resourceValues(forKeys: [.fileSizeKey]).fileSize == 11_242_036,
              try vocabulary.resourceValues(forKeys: [.fileSizeKey]).fileSize == 3352 else {
            throw Failure.unrecognizedAssets
        }
        let modelData = try Data(contentsOf: model)
        let vocabularyData = try Data(contentsOf: vocabulary)
        guard digest(modelData) == Self.modelSHA, digest(vocabularyData) == Self.vocabularySHA else {
            throw Failure.unrecognizedAssets
        }
        modelBytes = modelData
        policy = try PretrainedSignPolicy(vocabulary: JSONDecoder().decode([String: Int].self, from: vocabularyData))
        var options = Interpreter.Options()
        options.threadCount = 2
        // Avoid manually passing the experimental delegate-options struct
        // across header/runtime versions. The stable opaque C API is sufficient
        // for this CPU parity probe; measure before enabling more delegates.
        options.isXNNPackEnabled = false
        interpreter = try Interpreter(modelData: modelData, options: options)
    }

    deinit {
        interpreter = nil
        withExtendedLifetime(modelBytes) {}
    }

    func logits(_ frames: [LandmarkFrame]) throws -> [Float]? {
        guard let interpreter else { throw Failure.invalidOutput }
        guard let values = try PretrainedSignPolicy.pack(frames) else { return nil }
        if frameCount != frames.count {
            try interpreter.resizeInput(at: 0, to: Tensor.Shape([frames.count, 543, 3]))
            try interpreter.allocateTensors()
            frameCount = frames.count
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        try interpreter.copy(data, toInputAt: 0)
        try interpreter.invoke()
        let output = try interpreter.output(at: 0)
        guard output.dataType == .float32, output.data.count == 250*MemoryLayout<Float>.size else {
            throw Failure.invalidOutput
        }
        var result = Array(repeating: Float(0), count: 250)
        _ = result.withUnsafeMutableBytes { output.data.copyBytes(to: $0) }
        guard result.allSatisfy(\.isFinite) else { throw Failure.invalidOutput }
        return result
    }

    func classify(_ frames: [LandmarkFrame]) throws -> Classification {
        guard let values = try logits(frames) else {
            return Classification(candidates: [], unknown: true,
                                  reason: "insufficient_observation", model: PretrainedSignPolicy.modelName)
        }
        return try policy.decode(values)
    }
}
