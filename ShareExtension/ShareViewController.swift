import UIKit
import SwiftUI
import UniformTypeIdentifiers
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
                if saved { Label("Saved. Open Learn to finish importing.", systemImage: "checkmark.circle") }
                else if let pending { Section("Transcript") { Text(pending.text).lineLimit(12) }; Text("This import will be processed next time you open Learn.").font(.footnote).foregroundStyle(.secondary) }
                else if error == nil { ProgressView("Reading shared content…") }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Learn")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(saved ? "Close" : "Cancel") { context?.completeRequest(returningItems: nil) } }
                    ToolbarItem(placement: .confirmationAction) { if !saved { Button("Save") { save() }.disabled(pending == nil) } }
                }
        }.task { await load() }
    }
    @MainActor private func load() async {
        do {
            let items = (context?.inputItems as? [NSExtensionItem]) ?? []
            let providers = items.flatMap { $0.attachments ?? [] }
            for provider in providers {
                for type in [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    let value = try await provider.loadItem(forTypeIdentifier: type)
                    if let url = value as? URL {
                        if url.isFileURL {
                            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                            guard ["txt", "srt", "vtt"].contains(url.pathExtension.lowercased()) else { throw ImportError.service("Share a TXT, SRT, or VTT file.") }
                            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
                            let data = try Data(contentsOf: url)
                            guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
                            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidResponse }
                            pending = PendingImport(text: text, fileExtension: url.pathExtension, title: url.deletingPathExtension().lastPathComponent)
                        } else { _ = try EpisodeLink(url.absoluteString); pending = PendingImport(text: url.absoluteString) }
                    } else if let text = value as? String {
                        guard text.utf8.count <= 5_000_000 else { throw ImportError.tooLarge }
                        pending = PendingImport(text: text)
                    }
                    if pending != nil { return }
                }
            }
            throw ImportError.service("Share an Apple Podcasts episode link, English text, or a transcript file.")
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            guard let pending, let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw ImportError.service("App Group is unavailable. Check signing for both targets.") }
            let directory = container.appendingPathComponent("PendingImports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
            try JSONEncoder().encode(pending).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saved = true
        } catch { self.error = error.localizedDescription }
    }
}
