import SwiftUI

@main
struct SignloopApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--signloop-benchmark") {
                NativeGestureBenchmark().preferredColorScheme(.dark)
            } else {
                ContentView().preferredColorScheme(.dark)
            }
            #else
            ContentView()
                .preferredColorScheme(.dark)
            #endif
        }
    }
}
