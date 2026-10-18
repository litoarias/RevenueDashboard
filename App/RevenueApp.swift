import SwiftUI

@main
struct RevenueApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(model)
                .environment(\.locale, Locale(identifier: "es_ES"))
                .task {
                    #if os(macOS)
                    if !model.hasASC { _ = model.importFromAscMCP() }
                    #endif
                    model.requestRefresh()
                }
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif
    }
}
