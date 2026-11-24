import SwiftUI

@main
struct FingerBallCaptureApp: App {
    @StateObject private var model = CaptureModel()

    var body: some Scene {
        WindowGroup {
            CaptureScreen(model: model)
        }
    }
}
