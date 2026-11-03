import SwiftUI
import AVKit

struct DownloadedVideoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle("Downloaded Video").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause(); player = nil }
    }
}
