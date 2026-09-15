import SwiftUI

@main
struct IndexPhotosApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("IndexPhotos") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
