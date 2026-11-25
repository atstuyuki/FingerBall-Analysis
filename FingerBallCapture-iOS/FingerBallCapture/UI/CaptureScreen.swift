import SwiftUI
import AVFoundation

struct CaptureScreen: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CameraPreview(session: model.camera.session)
                        .frame(height: 230)
                        .listRowInsets(EdgeInsets())
                    Text("状態  \(model.state.rawValue)   ·   空き容量  \(model.remaining)")
                    if let issue = model.issue {
                        Text(issue).foregroundStyle(.red)
                    }
                    if model.role != .solo {
                        Text(model.connected ? "相手端末と接続済み" : "相手端末を探索中")
                        if !model.remoteStatus.isEmpty { Text("子機  \(model.remoteStatus)") }
                        Text("各端末は独立した時計で記録します。")
                            .font(.footnote)
                    }
                    if model.role != .recorder {
                        HStack {
                            Button("録画開始", systemImage: "record.circle", action: model.start)
                                .disabled(!model.canStart)
                                .accessibilityIdentifier("capture.start")
                            Spacer()
                            Button("停止", systemImage: "stop.circle", action: model.stop)
                                .disabled(model.state != .recording)
                                .accessibilityIdentifier("capture.stop")
                        }.buttonStyle(.borderless)
                    } else if model.state == .recording {
                        Button("この端末の録画を停止", role: .destructive) {
                            model.interrupted("子機で手動停止しました")
                        }
                    }
                }
                Section("撮影設定") {
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
                    if model.modes.isEmpty {
                        Button("カメラを再確認") { Task { await model.prepare() } }
                    }
                }.disabled(!model.canConfigure)
                Section("研究情報") {
                    if model.role == .recorder {
                        if let take = model.activeTake {
                            LabeledContent("研究ID", value: take.subjectID)
                            LabeledContent("投球番号", value: String(take.throwNumber))
                            LabeledContent("投球手", value: take.throwingHand)
                            LabeledContent("セッションID", value: take.sessionID.uuidString)
                        } else {
                            Text("撮影時に親機から研究情報を受信します。")
                        }
                    } else {
                        TextField("匿名研究ID（半角英数字、-、_）", text: $model.subject)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ThrowNumberField(number: $model.throwNumber)
                        Picker("投球手", selection: $model.throwingHand) {
                            Text("右").tag("R")
                            Text("左").tag("L")
                        }
                        LabeledContent("セッションID", value: model.sessionID.uuidString)
                        Button("新しいセッション") {
                            model.sessionID = UUID()
                            model.throwNumber = 1
                        }
                    }
                }.disabled(!model.canConfigure)
                Section("保存済みテイク") {
                    if model.saved.isEmpty { Text("保存済みの録画はありません") }
                    ForEach(model.saved, id: \.self) { folder in
                        NavigationLink {
                            ReviewScreen(folder: folder)
                        } label: {
                            TakeRow(folder: folder)
                        }
                    }
                }
            }
            .navigationTitle("FingerBall Capture")
            .task { await model.prepare() }
            .onChange(of: model.role) { model.changeRole() }
            .onChange(of: scenePhase) {
                switch scenePhase {
                case .background where !model.state.permitsNewTake:
                    model.interrupted("アプリがバックグラウンドに移行しました")
                case .active: model.refresh()
                default: break
                }
            }
        }
    }
}

private struct ThrowNumberField: View {
    @Binding var number: Int

    var body: some View {
        Stepper(value: $number, in: 1...99999) {
            HStack {
                Text("投球番号")
                TextField("番号", value: $number, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct TakeRow: View {
    let folder: URL

    var body: some View {
        if let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: folder.appending(path: "metadata.json"))) {
            VStack(alignment: .leading) {
                Text("\(metadata.subjectID) · 投球 \(metadata.throwNumber) · \(metadata.viewType.rawValue)")
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
