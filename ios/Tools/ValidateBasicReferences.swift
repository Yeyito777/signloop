import Foundation

@main struct ValidateBasicReferences {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw NSError(domain: "ReferenceSetup", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Usage: validate-references /path/to/basic-references.json"])
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size < 40_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let source = try JSONDecoder().decode(BasicReferenceBank.self, from: Data(contentsOf: url))
            let bank = try source.restricted(to: BasicSignScore.presentationVocabulary)
            let matcher = try BasicSignMatcher(bank: bank, weMotionScale: BasicSignMatcher.compactWEMotionScale)
            guard matcher.usableReferenceCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            print("Validated \(bank.labels.count) presentation labels and \(matcher.usableReferenceCount) usable references.")
        } catch {
            fputs("Reference validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
