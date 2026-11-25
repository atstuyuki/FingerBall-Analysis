# FingerBall Capture V1

投球研究用のiPhone/iPadアプリです。背面カメラで撮影し、元のサンプル時刻と手動イベントラベルを端末内に保存します。対象OSはiOS/iPadOS 17以降です。

## Xcodeで起動

1. `FingerBallCapture.xcodeproj` を開き、`FingerBallCapture` スキームを選択します。
2. 実機を接続し、ターゲットの Signing & Capabilities で開発チームを指定します。必要に応じてチーム固有のBundle Identifierを設定し、実機のデベロッパモードを有効にします。
3. Runでアプリを起動し、カメラを許可します。親機・子機で運用する際は両方でローカルネットワークを許可します。
4. XcodeGenはプロジェクトを再生成する場合に使います。通常は同梱のプロジェクトをそのまま開けます。

```sh
xcodebuild -list -project FingerBallCapture.xcodeproj
xcodebuild -project FingerBallCapture.xcodeproj -scheme FingerBallCapture \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project FingerBallCapture.xcodeproj -scheme FingerBallCapture \
  -destination "id=<Simulator UUID>" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## iPadでカメラが中断された場合

ホーム画面から録画用の **FingerBall Capture** を開きます。自動テスト実行時にXcodeがインストールするテストランナーは、XcodeのTest操作で使用します。iPadで別のアプリと画面を分割している場合は、FingerBall Captureを全画面にします。別アプリがカメラを使っている場合は、そのアプリを閉じてからFingerBall Captureに戻ります。アプリが前面に戻った際にカメラを再開し、カメラエラーが続く場合は画面の「カメラを再接続」を使えます。

## iPad Air第5世代での受入試験

単体録画の一部はXcodeの `FingerBallCaptureDevice` スキームでも検証できます。カメラを許可し、レンズをテスト用の無地の面に向けた状態で、接続したiPad Airを選んでTestを実行します。テストは固有の `TEST_` IDで約2秒録画し、保存した解像度・名目FPS・PTS照合とフレーム送りを画面で確認します。テイクは端末内に残ります。

テスト用研究ID `TEST_001` を使用し、撮影対象は目盛りや手元のテスト素材にします。保存が終わるまでアプリを前面に置きます。

1. **単体録画。** 「単体」「後方全体」を選び、投球番号1と投球手を設定します。目標欄と録画形式欄が1920×1080 / 240 fpsを表示することを確認します。候補に240 fpsが出ない端末では、警告と手動選択が表示されることを確認します。明暗や横・縦持ちを変えて数秒ずつ録画し、プレビューと再生の向きを確認します。露光・フォーカス固定を切り替え、メタデータに実際のモードが入ることも確認します。
2. **映像と時刻。** Filesの「このiPad内」またはZIPから、下記のファイルを取得します。`actual_video_properties` の解像度、名目FPS、`ptsMatch`、フレーム数と、CSVの `accepted_by_writer=true` の件数を照合します。240 fpsで連続したフレーム同士の元PTS差は約4.17 msです。ドロップの行と時刻差も確認し、30秒程度の撮影を繰り返して継続記録・発熱・空き容量を確認します。macOSで独立に数える場合は下記のffprobeを使えます。
3. **2端末。** iPad AirとiPhoneを同じ場所で起動し、片方を「親機」、他方を「子機」にします。両方で撮影形式と異なる視点を選び、親機で研究情報を入力して録画開始・停止します。双方で保存され、研究ID・投球番号・`session_id`・`take_id` が一致し、`device_id`・視点が区別されることを確認します。`capture_events.jsonl` で arm/start/stop の指示と応答を照合します。両端末に写るBRを独立にラベルすれば、後の同期評価に使用できます。端末ごとに時計基準が異なり、無線指示の時刻差からフレーム同期の精度は測れません。
4. **通信断と中断。** 録画中に片方を切断し、両端末で部分失敗が表示され、切断までのデータが保存されることを確認します。接続を復帰し、次のテイクを開始できることを確認します。ローカルネットワーク許可の拒否・再許可、録画中のアプリのバックグラウンド移行、録画直後の停止でも確認します。
5. **レビュー。** 1コマ送りとスライダーで対象コマへ移動し、BRとSFCを記録します。視野外のイベントでは「未観測」を選びます。レビューを開き直し、ラベルが復元されることを確認します。ZIPをFilesへ保存して元のテイクが残り、注釈を含むファイルを開けることを確認します。

```sh
ffprobe -v error -select_streams v:0 -count_frames \
  -show_entries stream=width,height,r_frame_rate,avg_frame_rate,nb_read_frames \
  -of default=noprint_wrappers=1 original.mov
```

## データの見方

```text
FingerBallExports/
  session_<UUID>/
    session_manifest.json
    device_<UUID>/
      take_<投球番号>_<UUID>/
        original.mov
        frame_timestamps.csv
        metadata.json
        capture_events.jsonl
        annotations.json
```

- `original.mov` はAVFoundationサンプルからリアルタイムにH.264で保存します。音声は収録しません。
- CSVは受信順・ドロップ通知順に0始まりの行番号を付け、カメラのPTSの整数値・タイムスケールとwriterへの受理結果を残します。MOV側の時刻は最初の有効な入力PTSを基準に正規化します。録画後にAVAssetReaderでMOVの全フレーム数とPTSを照合し、レビュー画面に保存FPSと欠落数を表示します。失敗時は保存済みのデータを「部分失敗」として残します。
- 手動ラベルのフレーム番号はJSONでは0始まり、画面では1始まりです。未観測にはフレーム番号やPTSを設定しません。録画条件の露光・ISO・レンズ位置は開始時の値です。
- Filesからはセッション全体を参照できます。アプリの共有ボタンは選択テイクのZIPを作ります。
- 将来の手指21点、肩肘姿勢、YOLOボール追跡は `AnalysisModule` プロトコルを実装し、保存済みのテイクを入力にします。推論結果と手動注釈は別の成果物として保存できます。
