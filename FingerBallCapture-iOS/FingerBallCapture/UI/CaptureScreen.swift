import SwiftUI
import AVFoundation

struct CaptureScreen: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var widthClass
    @FocusState private var editingResearch: ResearchField?
    private enum ResearchField { case id, name }
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                researchBar
                CameraPreview(session: model.camera.session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("カメラプレビュー")
                    .accessibilityIdentifier("capture.preview")
                    .overlay(alignment: .topLeading) {
                        if let message = model.cameraIssue ?? model.issue {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).font(.footnote)
                                if model.cameraIssue != nil {
                                    Button("カメラを再接続") { Task { await model.prepare(restart: true) } }
                                        .buttonStyle(.bordered)
                                        .disabled(!model.state.permitsNewTake)
                                }
                            }
                            .padding(10)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.8), in: .rect(cornerRadius: 10))
                            .padding(8)
                        }
                    }
                controls
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .navigationTitle("FingerBall Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editingResearch = nil
                        showingSettings = true
                    } label: {
                        if widthClass == .regular {
                            Label("撮影設定", systemImage: "gearshape").labelStyle(.titleAndIcon)
                        } else {
                            Label("撮影設定", systemImage: "gearshape").labelStyle(.iconOnly)
                        }
                    }
                    .disabled(!model.canConfigure)
                    .accessibilityIdentifier("capture.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SavedVideosScreen(model: model)
                    } label: {
                        if widthClass == .regular {
                            Label("保存済み動画", systemImage: "folder").labelStyle(.titleAndIcon)
                        } else {
                            Label("保存済み動画", systemImage: "folder").labelStyle(.iconOnly)
                        }
                    }
                    .disabled(!model.canConfigure)
                    .accessibilityIdentifier("capture.library")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { editingResearch = nil }
                }
            }
            .sheet(isPresented: $showingSettings) {
                CaptureSettingsScreen(model: model)
            }
            .onChange(of: model.role) { model.changeRole() }
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .active { model.foregroundChanged(true) }
                if scenePhase == .background { model.foregroundChanged(false) }
            }
        }
    }

    @ViewBuilder
    private var researchBar: some View {
        if model.role == .recorder {
            HStack {
                Text(model.activeTake?.subjectID ?? "研究IDを親機から受信")
                Spacer()
                if let number = model.activeTake?.throwNumber { Text("投球 \(number)") }
            }
            .font(.subheadline)
        } else {
            HStack(spacing: 8) {
                TextField("研究ID", text: $model.subject)
                    .accessibilityIdentifier("capture.subjectID")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editingResearch, equals: .id)
                    .submitLabel(.next)
                    .onSubmit { editingResearch = model.subject.isEmpty ? nil : .name }
                TextField("名前（任意）", text: Binding(get: { model.subjectName }, set: { model.subjectName = $0 }))
                    .accessibilityIdentifier("capture.subjectName")
                    .focused($editingResearch, equals: .name)
                    .submitLabel(.done)
                    .onSubmit { editingResearch = nil }
                    .disabled(model.subject.isEmpty)
                Text("投球 \(model.throwNumber)")
                    .font(.subheadline.monospacedDigit())
                    .accessibilityIdentifier("capture.throwNumber")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!model.canConfigure)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.state.rawValue)
                    .font(.subheadline.weight(.semibold))
                Text(model.mode?.label ?? "撮影形式を選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.role != .solo {
                    Text(model.connected ? "相手端末と接続済み" : "相手端末を探索中")
                        .font(.caption)
                    if !model.remoteStatus.isEmpty {
                        Text("子機 \(model.remoteStatus)")
                            .font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("空き容量 \(model.remaining)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            recordButton
        }
    }

    private var recordButton: some View {
        let recording = model.state == .recording
        return Button {
            editingResearch = nil
            if recording {
                if model.role == .recorder { model.interrupted("子機で手動停止しました") }
                else { model.stop() }
            } else {
                model.start()
            }
        } label: {
            Label(recording ? "録画停止" : "録画開始",
                  systemImage: recording ? "stop.fill" : "record.circle")
                .frame(minWidth: 80, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!recording && !model.canStart)
        .accessibilityIdentifier(recording ? "capture.stop" : "capture.start")
    }
}

private struct CaptureSettingsScreen: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("撮影") {
                    Picker("役割", selection: $model.role) {
                        ForEach(DeviceRole.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("視点", selection: $model.view) {
                        ForEach(Viewpoint.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("目標", value: CameraMode.target.label)
                    Picker("録画形式", selection: $model.mode) {
                        Text("選択してください").tag(nil as CameraMode?)
                        ForEach(model.modes, id: \.label) { Text($0.label).tag(Optional($0)) }
                    }
                    if !model.modes.contains(CameraMode.target) && !model.modes.isEmpty {
                        Text("この背面カメラで1080p/240fpsを選べません。録画形式を指定してください。")
                            .foregroundStyle(.orange)
                    }
                    Toggle("露光・ISOを固定（対応端末）", isOn: $model.lockExposure)
                    Toggle("フォーカスを固定（対応端末）", isOn: $model.lockFocus)
                    if let mode = model.mode, mode.fps >= 120 {
                        Text("高速撮影は停止後に動画を作成します。1080p/240fpsでは1秒あたり約0.75 GBの一時領域が必要です。")
                            .font(.footnote)
                    }
                    if model.role != .solo {
                        Text("各端末は独立した時計で記録します。").font(.footnote)
                    }
                }
                if model.role != .recorder {
                    Section {
                        TextField("投球番号", value: $model.throwNumber, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                        Picker("投球手", selection: $model.throwingHand) {
                            Text("右").tag("R")
                            Text("左").tag("L")
                        }
                        LabeledContent("セッションID", value: model.sessionID.uuidString)
                        Button("新しいセッション") {
                            model.sessionID = UUID()
                            model.throwNumber = 1
                        }
                    } header: {
                        Text("研究情報")
                    } footer: {
                        Text("名前はこの端末の一覧表示用です。研究IDが録画データに記録されます。")
                    }
                }
            }
            .navigationTitle("撮影設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

private struct SavedVideosScreen: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        List {
            if model.saved.isEmpty { Text("保存済みの動画はありません") }
            ForEach(model.saved, id: \.self) { folder in
                NavigationLink {
                    ReviewScreen(folder: folder)
                } label: {
                    TakeRow(folder: folder, displayName: model.displayName)
                }
            }
        }
        .navigationTitle("保存済み動画")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refresh() }
    }
}

private struct TakeRow: View {
    let folder: URL
    let displayName: (String) -> String?

    var body: some View {
        if let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: folder.appending(path: "metadata.json"))) {
            VStack(alignment: .leading) {
                Text("\(metadata.subjectID) · 投球 \(metadata.throwNumber) · \(metadata.viewType.rawValue)")
                if let name = displayName(metadata.subjectID) { Text(name).font(.subheadline) }
                Text("\(metadata.status) · \(metadata.actualVideoProperties.map { String(format: "%.2f fps", $0.nominalFPS) } ?? "FPS未計測")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(folder.lastPathComponent)
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection else { return }
            let angle: CGFloat
            switch window?.windowScene?.interfaceOrientation {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            default: angle = 0
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
