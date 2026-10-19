import FaceIDAppKit
import SwiftUI

@main
struct FaceIDMenuBarApp: App {
    @State private var model = AppModel(client: XPCAgentClient.makeDefault(), settings: UserDefaultsEnabledSetting())

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(AppStrings.title)
        }
        .menuBarExtraStyle(.window)
    }
}
