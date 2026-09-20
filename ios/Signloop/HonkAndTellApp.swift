import SwiftUI

@main
struct HonkAndTellApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--signloop-skeleton-benchmark") {
                NativeSkeletonBenchmark().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--signloop-live-replay") {
                NativeLiveReplay().preferredColorScheme(.dark)
            } else {
                debugContent
            }
            #else
            debugContent
            #endif
            #else
            ContentView()
                .preferredColorScheme(.dark)
            #endif
        }
    }

    #if DEBUG
    @ViewBuilder private var debugContent: some View {
            if ProcessInfo.processInfo.arguments.contains("--signloop-pretrained-benchmark") {
                NativePretrainedBenchmark().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--signloop-benchmark") {
                NativeGestureBenchmark().preferredColorScheme(.dark)
            } else {
                ContentView().preferredColorScheme(.dark)
            }
    }
    #endif
}
