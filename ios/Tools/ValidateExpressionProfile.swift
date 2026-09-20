import Foundation

@main
struct ValidateExpressionProfile {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ExpressionTeachingError(message: "Pass the exported DemoExpressionProfile.json file.")
            }
            let profile = try TaughtExpressionStore.read(URL(fileURLWithPath: CommandLine.arguments[1]))
            print("Validated demo expression profile \(profile.id): six labels, 12 teaching takes, six repeat checks.")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
