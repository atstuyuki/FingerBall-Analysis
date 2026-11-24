# FingerBall Capture V1 — Codex開発引継ぎ書

**2026-11-24 / Status: 研究方針確定、iOSアプリ未実装**  
**既存Repo:** https://github.com/atstuyuki/FingerBall-Analysis  
**新設:** `FingerBallCapture-iOS/`（既存の `notebooks/` は維持）  
**最初の実機:** iPad Air 第5世代（M1、256GB）、iPhone/iPad共通対応

> Codexへ：本書とルートの `AGENTS.md` を読んでから着手。最優先は**実際にXcodeで開けるV1プロジェクト**と、単体240fps録画＋元フレーム時刻の正確な保存、2端末無線連動。ビルドや実機動作は実行した場合にのみ成功と報告する。

## 1. 研究目的・絶対条件

このプロジェクトは投球リリース付近の手指動作、とくに示指・中指の関節運動・ボール離脱タイミングを定量化するためのもの。まず **2台のiPhone/iPadで1投球を後方正面（フォーム全体）と後方斜め／手部拡大から同時収録**して教師データを作る。最終的な実用構成は **カメラ1台＋IMUセンサ1台**。

- **採用:** 無線連動録画（親機が子機のSTART/STOPを指示）、1080p/240fps優先、撮影後のイベント同期。
- **不採用:** LED光信号、Genlock、別のハードウェア同期機器。通信による録画開始が「フレーム同期」の保証だと表現しない。
- **将来のMLイベント同期:** ボールリリース（BR）を主要共通イベントに、前足接地（SFC）は映る視点の投球相ラベルに利用する。240fpsで1〜2コマ≒4.17〜8.33msの**許容目標**。精度は独立した目視レビューラベルで測る。SFCとBRという別イベントをそのまま同一時刻に合わせてはいけない。
- **将来の解析モード:** Hand = 手指21点、Shoulder/Elbow = 上肢・投球相、Ball = YOLOのボール検出・軌跡。V1は各モードの拡張インターフェースを作るが、重いAI処理を240fps撮影中には行わない。
- **3D注意:** 2台の動画で厳密な3D教師値を作るには、カメラ内部・外部パラメータと歪み、時間同期、両視点可視性の検証が別途必要。単眼WiLoR出力は推定3Dであって実測3Dではない。

## 2. 過去の研究と既存コード（既にGitHubに保存済み）

既存READMEにはStageごとの実装履歴とColabリンクがある。以下を壊さない。

| 資産 | GitHub相対パス | 備考 |
|---|---|---|
| 手指2D手動補正 | `notebooks/FingerBall_v2_Stage2H_Manual_Guided_Annotation.ipynb` | Stage2H。座標は元動画ピクセルのXYのみ手動補正。遮蔽・AI・候補引継ぎは区別。 |
| 360°スティック | `notebooks/FingerBall_Stage2H_Spinoff_360_Stick_Viewer.ipynb` | HTMLを別出力。疑似3D。 |
| MediaPipe vs WiLoR-mini | `notebooks/FingerBall_Stage2J1_MultiModel_2D3D_Comparison.ipynb` | Stage2J-1。WiLoRは独立Python3.10環境・dill依存修正済み。MANOライセンス注意。 |
| 指関節QC＋3D viewer | `notebooks/FingerBall_Stage2J1B_Detailed_QC_3D_Viewer.ipynb` | Stage2J-1B。登録済みだがColab全実行検証済みとは限らない。 |
| MANOフィッティング | `notebooks/FingerBall_Stage2I2_MANO_3D_Mesh_Fitting.ipynb` | 参考実装。MANOモデルはGitに入れない。 |

研究上の旧動画例：`7A5812501DC5F7120DF842D06EE1B74C695459F1.mp4`、旧サンプルは約29.99fps・1206×648、投球手Left、185〜198フレームに目視補正、リリース参照190F。この値は**古い1動画固有**であり、新アプリでは固定しない。

旧Stage2J-1レビュー：14FでWiLoR＋手動bboxは14/14検出、2D RMSE約26.7px。MediaPipe＋手動ROIは8/14、約42.7px。WiLoR全画面は2/14、約84.9px、MediaPipe全画面は0/14。**少数フレームでの2D手動座標との一致度**であり、臨床的3D角度精度の証明ではない。手動ROIと独立検出は区別。

旧Google Driveの例：`/content/drive/MyDrive/母指回内トラッキング/`。iOSの保存先ではない。

## 3. V1の必須機能

### A. Capture（単体録画）

1. **SwiftUI iPhone/iPad共通App**を作る。背面カメラを使用し、撮影視点「後方全体／後方斜め／手部拡大」を選択。
2. `AVCaptureDevice.Format`の実デバイス対応解像度・`videoSupportedFrameRateRanges`を列挙し、利用可能なら**1920×1080@240fps**を選ぶ。対応不可なら警告し、対応FPS候補を明示してユーザーに選択させる。画面表示の「目標240fps」と「実際の設定／保存済み動画のfps」を区別する。
3. 端末が許す範囲で**露光時間・ISO・フォーカス固定**（オート可否明示）、カメラ・焦点距離/ズーム・手ブレ補正設定・向き等を記録。1/2000秒は明るさ次第で狙う値であり必須達成値ではない。
4. 被験者**匿名研究ID**、投球番号、右/左手、視点、セッションUUID。患者名・生年月日は入力必須にしない。
5. プレビューと録画START/STOP、ステータス、残容量/エラー表示。録画中に骨格推論はしない。
6. 元映像は高速度の元フレームと実PTSを保持する形式で保存。**30fpsに間引いたスローモーションを原データとして扱わない**。
7. `AVCaptureVideoDataOutput`＋`AVAssetWriter`等で元の`CMSampleBuffer`のPTS(`CMTime.value`, `CMTime.timescale`)を保存。各サンプルの受信・writerへの受理・ドロップ・中断を追跡し、**動画内フレームとCSVの整合性を後から確認**できること。重い前処理は撮影パスで禁止。バッファのライフタイム、バックプレッシャー、保存完了を正しく処理。
8. 元動画（例`original.mov`）、各フレームの`frame_timestamps.csv`、撮影条件`metadata.json`、エラー/状態`capture_events.jsonl`を**ローカル保存**。録画後にFiles/共有シートへエクスポート。
9. 録画後の再生・フレーム単位スクラブ、**BR/SFCイベントの手動指定**とラベル保存（映らないイベントは未観測）。

### B. Multi-device（無線連動）

- `MultipeerConnectivity`で親機/子機を探索・ペアリング。必要なBonjourサービスとローカルネットワーク権限をプロジェクト設定に入れる。
- 親機・子機で**同じsession_id・take_id**を共有。親機が自機と子機の録画開始・停止を制御し、双方向にACK・状態・失敗を受信。
- 状態遷移例：`idle -> paired -> configured -> armed -> recording -> finishing -> saved`。
- 各指示にユニークなcommand_idを持たせ、重複受信による二重録画を防ぐ。送受信・ACK/端末独立の時刻をイベントログ化。
- 無線制御は撮影開始操作の連動にすぎず、**タイムスタンプの時計基準は両端末で独立**。2つのPTSをそのまま比較して同期済みとはしない。
- 動画は各端末で保存。240fps撮影中に端末間で生動画をストリーミングしない。通信断でも収録済みデータを保持し、明示的に部分失敗と記録。

### C. 保存構造（案）

```text
FingerBallExports/
  session_<UUID>/
    session_manifest.json
    device_<id>/
      take_0003/
        original.mov
        metadata.json
        frame_timestamps.csv
        capture_events.jsonl
        annotations.json
        analysis/      # 将来: hand, pose, ball
```

`metadata.json`に`schema_version`, `session_id`, `take_id`, `device_id`, `device_role`, `view_type`, `subject_id`, `throwing_hand`, `device_model`, `app_version`, `ios_version`, `target_fps`, `selected_format`, `actual_video_properties`, `exposure_duration`, `iso`, `focus`, `zoom`, `orientation`, `frame_count`, `drop_count`, `capture_clock_info`等。実際に取れない値は空欄／`unavailable`とする。

`frame_timestamps.csv`は少なくとも`record_index,source_pts_value,source_pts_timescale,source_pts_seconds,writer_pts_seconds,accepted_by_writer`を持つ設計にし、動画側のフレームと再照合する処理を作る。差分は`capture_events.jsonl`に残す。未確定イベントを「正解」として上書きしない。

### D. V1対象外

- LED同期、Genlock、WiLoR/SOMA/MANOのiOS端末内3D推論。
- YOLO学習やCore ML変換、リアルタイムHand/肩肘/Ball解析（将来モジュールのinterfaceとディレクトリだけ用意）。
- USB外部マイクは将来の任意拡張でありV1のブロッカーではない。
- 外部サイトやクラウドへの動画の無断アップロード、元データの自動削除。

## 4. 将来の解析とイベント同期

- **V2 Event Sync:** 両動画に写る**同一イベント BR**でオフセットを推定。SFCは全身視点に映る場合のイベント候補に使う。手動レビュー済みとML推定値を別フィールドにし、信頼度・モデル版・基準フレームを残す。可能ならセッション前後の同一イベントからドリフトも点検。
- **V2 Hand:** 21点、示指/中指のMCP/PIP/DIP/TIPとボール離脱。既存Stage2H→2J1/2J1BのCSV・provenanceを参照。
- **V2 Shoulder/Elbow:** 肩・肘・手関節・体幹・SFCなどの骨格。姿勢の画角依存を評価。
- **V2 Ball:** 投球動画をアノテーションしてYOLOボール検出モデルを学習、中心・bbox・信頼度・軌跡・ID・見失い区間を保存。後でCore ML on-deviceを検討。
- **V3 Teacher Data:** 2視点キャリブレーション、同期品質、手動正解／推定の由来を保持した3D/2D教師データ。
- **V4:** 1カメラ＋1IMU。IMUだけでは各指の関節角度は直接測れない。

## 5. コード・フォルダ構造

```text
FingerBall-Analysis/
  README.md                  # 既存内容は維持、V1へのリンクのみ追加
  AGENTS.md
  docs/FingerBall_Capture_V1_Codex_Handoff.md
  notebooks/                 # 既存、変更しない
  FingerBallCapture-iOS/
    README.md
    FingerBallCapture.xcodeproj/
    FingerBallCapture/
      App/
      UI/
      Capture/               # format selection, AVCapture, AVAssetWriter, PTS
      Peer/                  # MultipeerConnectivity, state/ACKs
      Models/                # metadata, session, take, event schema
      Storage/               # local files, export
      Analysis/              # Hand/Pose/Ball future protocols/stubs
      Resources/
    FingerBallCaptureTests/
```

実装上のクラス例：`CameraFormatSelector`, `CaptureService`, `RecordingWriter`, `FrameTimestampLogger`, `PeerSessionService`, `SessionStore`, `EventAnnotation`, `AnalysisPipelineProtocol`。実際の設計に合わせて変更可。

## 6. Codex開発順序（必ずマイルストーン順）

**M0 既存Repo確認:** main/README/notebooksの現状を読んで、既存コードを温存。できれば`feature/fingerball-capture-v1`ブランチとPRで作業。force-pushしない。

**M1 単体240fps撮影:** Xcodeプロジェクト・権限・UI・対応format列挙・録画・元動画・PTS CSV・metadata JSON・保存整合性検証を最優先。iPad実機未テストなら明示。

**M2 無線連動:** Multipeer親子ペアリング、役割/状態/ACK、重複コマンド防止、2端末でローカル保存、通信断時のエラー表示。

**M3 撮影後レビュー:** 保存済みTake一覧、元フレーム表示、BR/SFC手動イベント、書き出し。Hand/Pose/Ballはインターフェースだけ。

**M4 テスト・納品:** unit tests（format selector、状態遷移、schema roundtrip、timestamp序列、重複コマンド）、macOSが使えるなら`xcodebuild -list -project FingerBallCapture-iOS/FingerBallCapture.xcodeproj`とSimulatorビルド。**Simulatorは240fps実機カメラの代わりにならない**。iPad Air5＋2台目のiPhoneで実機録画・PTS/動画フレーム数・2台接続・通信断の検証手順をREADMEに書く。

## 7. 受入条件と納品物

- 実在する`.xcodeproj`、Swiftソース、権限・Bonjour設定、テスト、README、`.gitignore`。
- 1080p240撮影可能端末の自動判定と実際のフォーマット選択。サイレントFPS低下なし。
- 研究ID/投球番号/視点と元動画・frame timestamp・metadata・イベントログ。
- 2端末の親機操作で両機が録画開始・終了。session/take UUID共有、データ各端末保存。
- 再生・フレーム確認・リリース等の手動ラベル・エクスポート。
- 既存notebooks不変。MANO資産、実研究動画、被験者個人情報、認証情報をGitHubに置かない。
- ビルド／実機で行っていない試験を「成功」と断定しない。
- GitHubの該当コードリンク、更新ファイル、動作確認内容、既知問題、次の実機テスト手順を最終報告。

## 8. GitHub運用

Repoは`atstuyuki/FingerBall-Analysis`。iOSを`FingerBallCapture-iOS/`へ追加。小さな機能ごとにcommit、feature branchからPRを推奨。READMEは追記・既存Notebookは変更しない。`.gitignore`でDerivedData、ユーザー固有のXcode状態、ビルド成果物、録画mov/mp4、生CSV/JSON、研究データを除外。**project.pbxprojやソース、Info.plist設定、テスト、匿名ダミーfixturesはGitに含める**。GitHubアクセス不可時はzipを納品し手動アップロード方法を記す。

## 9. Codexへの最初の指示（そのまま使用）

> `AGENTS.md` と `docs/FingerBall_Capture_V1_Codex_Handoff.md` を読み、既存のnotebooksを残したまま `FingerBallCapture-iOS/` に実際にXcodeで開けるSwiftUI+AVFoundationのiPhone/iPadアプリを新規実装してください。まず単体端末の1080p240撮影・実PTS記録・元動画/metadata/研究ID保存を完成させ、次にMultipeerConnectivityで親機/子機のstart/stop連動とACK/状態ログ、最後に撮影後イベント手動指定とFiles書き出しを実装してください。LED同期は不要。各端末のPTSは独立した時計基準です。実機検証できない項目は未検証と明記し、コミット・PR・README・実機テスト手順まで提供してください。

---
本書は仕様書であり、Xcodeビルドや240fps実機撮影の完了を意味しません。