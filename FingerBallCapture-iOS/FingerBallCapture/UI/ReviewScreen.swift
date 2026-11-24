import SwiftUI
import AVKit

struct ReviewScreen: View {
    let folder: URL
    @State private var player = AVPlayer()
    @State private var frames: [FrameTime] = []
    @State private var index = 0
    @State private var ready = false
    @State private var issue: String?
    @State private var annotations = Annotations()
    @State private var export: Export?

    var body: some View {
        Form {
            Section {
                VideoPlayer(player: player)
                    .frame(height: 280)
                if let issue { Text(issue).foregroundStyle(.red) }
                if !frames.isEmpty {
                    Text("フレーム \(index + 1) / \(frames.count) · \(frames[index].time.seconds.formatted(.number.precision(.fractionLength(6)))) 秒")
                        .monospacedDigit()
                    if frames.count > 1 {
                        Slider(value: Binding(get: { Double(index) }, set: { seek(Int($0)) }),
                               in: 0...Double(frames.count - 1), step: 1)
                            .accessibilityLabel("フレーム")
                    }
                    HStack {
                        Button("前のフレーム") { seek(index - 1) }.disabled(index == 0)
                        Spacer()
                        Button("次のフレーム") { seek(index + 1) }.disabled(index == frames.count - 1)
                    }.buttonStyle(.borderless)
                }
            }
            Section("手動イベント") {
                ForEach(PitchEvent.allCases, id: \.self) { event in
                    VStack(alignment: .leading) {
                        Text(event.label).font(.headline)
                        if let label = annotations.labels.first(where: { $0.event == event }) {
                            Text(label.frameIndex.map { "フレーム \($0 + 1)" } ?? "未観測")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("このフレームを指定") { annotate(event, observed: true) }
                                .disabled(!ready)
                            Spacer()
                            Button("未観測") { annotate(event, observed: false) }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Button("テイクをZIPで共有", systemImage: "square.and.arrow.up", action: exportTake)
        }
        .navigationTitle("撮影レビュー")
        .task {
            let annotationURL = folder.appending(path: "annotations.json")
            if FileManager.default.fileExists(atPath: annotationURL.path) {
                do { annotations = try JSONDecoder().decode(Annotations.self, from: Data(contentsOf: annotationURL)) }
                catch { issue = error.localizedDescription }
            }
            do {
                let url = folder.appending(path: "original.mov")
                frames = try await VideoFrames.inspect(url).1
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                seek(0)
            } catch { issue = error.localizedDescription }
        }
        .onDisappear { player.pause() }
        .sheet(item: $export, onDismiss: { export = nil }) { item in
            ShareSheet(url: item.url)
        }
    }

    private func seek(_ proposed: Int) {
        guard !frames.isEmpty else { return }
        let destination = min(max(proposed, 0), frames.count - 1)
        index = destination
        ready = false
        player.pause()
        player.seek(to: frames[destination].time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            DispatchQueue.main.async {
                if index == destination { ready = finished }
            }
        }
    }

    private func annotate(_ event: PitchEvent, observed: Bool) {
        if observed {
            // Playback controls can move the playhead independently of the frame buttons.
            let playhead = player.currentTime()
            guard ready, player.rate == 0, frames[index].time == playhead else {
                seek(index)
                issue = "指定フレームに移動しました。映像を確認してから再度指定してください。"
                return
            }
        }
        var next = annotations
        next.labels.removeAll { $0.event == event }
        next.labels.append(EventAnnotation(event: event, frameIndex: observed ? index : nil,
                                           moviePTS: observed ? frames[index] : nil,
                                           observation: observed ? "observed" : "not_observed"))
        do {
            try SessionStore.writeJSON(next, to: folder.appending(path: "annotations.json"))
            annotations = next
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    private func exportTake() {
        Task {
            do {
                let archive = try await Task.detached { try TakeArchive.create(folder) }.value
                export = Export(url: archive)
            } catch { issue = error.localizedDescription }
        }
    }
}

private struct Export: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
