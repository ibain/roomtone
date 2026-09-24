import AppKit
import SwiftUI

extension AppearancePreference {
    /// nil = follow macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension AppModel {
    /// App-wide so the Settings scene, the recording HUD panel and alerts follow too.
    func applyAppearance() {
        NSApp.appearance = settings.appearance.nsAppearance
    }

    func setAppearance(_ appearance: AppearancePreference) {
        guard settings.appearance != appearance else { return }
        var next = settings
        next.appearance = appearance
        settings = next
        next.save()
        applyAppearance()
    }
}

/// Sun/moon toolbar button. Click flips the current appearance; right-click to match the system.
struct AppearanceToggle: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Button {
            appModel.setAppearance(isDark ? .light : .dark)
        } label: {
            Label(
                isDark ? "Dark Appearance" : "Light Appearance",
                systemImage: isDark ? "moon.fill" : "sun.max.fill"
            )
        }
        .help(isDark ? "Switch to Light appearance (right-click for more)" : "Switch to Dark appearance (right-click for more)")
        .contextMenu {
            Picker("Appearance", selection: Binding(
                get: { appModel.settings.appearance },
                set: { appModel.setAppearance($0) }
            )) {
                Text("Light").tag(AppearancePreference.light)
                Text("Dark").tag(AppearancePreference.dark)
                Divider()
                Text("Match System").tag(AppearancePreference.system)
            }
            .pickerStyle(.inline)
        }
    }
}
