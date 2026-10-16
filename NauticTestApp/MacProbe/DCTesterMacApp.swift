#if os(macOS)
import SwiftUI

@main
struct DCTesterMacApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        Window("DC Tester Probe", id: "probe") {
            ProbeView(model: model)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 920, height: 860)
    }
}
#endif
