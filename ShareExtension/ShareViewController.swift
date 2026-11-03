import UIKit
import SwiftUI
import PodcastCore

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareContent(context: extensionContext))
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
    }
}

private struct ShareContent: View {
    let context: NSExtensionContext?
    @State private var pending: PendingImport?
    @State private var error: String?
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                if saved { Label("Saved. Open PodLearn to finish importing.", systemImage: "checkmark.circle") }
                else if let pending { Section((try? BilibiliLink(pending.text)) != nil || (try? EpisodeLink(pending.text)) != nil ? "Link" : "Transcript") { Text(pending.text).lineLimit(12).textSelection(.enabled) }; Text("This import will be processed next time you open PodLearn.").font(.footnote).foregroundStyle(.secondary) }
                else if error == nil { ProgressView("Reading shared content…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.navigationTitle("PodLearn")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(saved ? "Close" : "Cancel") { context?.completeRequest(returningItems: nil) } }
                    ToolbarItem(placement: .confirmationAction) { if !saved { Button("Save") { save() }.disabled(pending == nil) } }
                }
        }.task { await load() }
    }
    @MainActor private func load() async {
        do {
            let items = (context?.inputItems as? [NSExtensionItem]) ?? []
            pending = try await PendingImport.load(from: items)
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            guard let pending else { return }
            let info = Bundle.main.infoDictionary ?? [:]
            guard let group = PendingImport.appGroupIdentifier(in: Bundle.main),
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
                    .flatMap { try? Data(contentsOf: $0) }
                var report = "App Group is unavailable.\n\nExtension:\n" + PendingImport.appGroupDiagnostics(in: info, provisioningProfile: profile)
                let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                if let app = Bundle(url: appURL) {
                    let appProfile = app.url(forResource: "embedded", withExtension: "mobileprovision")
                        .flatMap { try? Data(contentsOf: $0) }
                    report += "\n\nApp:\n" + PendingImport.appGroupDiagnostics(in: app.infoDictionary ?? [:], provisioningProfile: appProfile)
                }
                throw ImportError.service(report)
            }
            let directory = container.appendingPathComponent("PendingImports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
            try JSONEncoder().encode(pending).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saved = true
        } catch { self.error = error.localizedDescription }
    }
}
