import SwiftUI
import SwiftData
import PodcastCore

@main struct PodcastLearningApp: App {
    @State private var settings: SettingsStore
    @State private var store: AppStore?
    @State private var player = ClipPlayer()
    private let container: ModelContainer?
    private let startupError: String?
    init() {
        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        do {
            let cloud = Bundle.main.object(forInfoDictionaryKey: "CloudSyncEnabled") as? String == "YES"
            let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String ?? ""
            let config = ModelConfiguration(schema: LearningSchema.schema, cloudKitDatabase: cloud ? .private(identifier) : .none)
            let container = try ModelContainer(for: LearningSchema.schema, configurations: config)
            let store = try AppStore(context: container.mainContext, settings: settings)
            self.container = container
            _store = State(initialValue: store)
            startupError = nil
        } catch { container = nil; startupError = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let container, let store {
                LibraryView().modelContainer(container).environment(store).environment(settings).environment(player).tint(Palette.accent)
            } else {
                ContentUnavailableView("Library Could Not Open", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Your data has not been erased. Check signing and iCloud configuration, then reopen the app.\n\n\(startupError ?? "Unknown error")"))
            }
        }
    }
}
