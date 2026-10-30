# FingerBall Analysis v2

単眼投球動画から手指の動きを解析するプロジェクトです。**Stage 1は全フレームの手検出とWiLoR INT8の生テンソル保存**まで対応しています。

[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)

**[Google ColabでStage 1を開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)**

## Stage 2H：Manual-guided Hand Landmark Annotation（188〜193を含むリリース周辺）

[![Open Stage 2H in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2H_Manual_Guided_Annotation.ipynb)

**[Stage 2HをColabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2H_Manual_Guided_Annotation.ipynb)**

Stage 2Dで得た元動画座標の21点CSVを読み込み、**元動画上で関節点をドラッグ修正**するColab GUI。 **隣接フレームへの補正候補の自動引継ぎ**に対応し、遮蔽点は隣接フレームの候補を消しません（紫色で要確認）。遮蔽・不明点のフラグ、セッションのDrive保存と再開、任意のキーフレーム間2D補間、元推定との比較PNG・監査CSV・ZIPを生成します。**Zは修正しておらず、2Dの修正を真の3D補正と混同しない**でください。`VIDEO_PATH`には元動画を指定してください（拡大済み動画は不可）。

## Stage 2G：Release-focused viewer（188–193フレーム）

[![Open Stage 2G in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2G_Release_Focused_Viewer.ipynb)

**[Stage 2GをColabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2G_Release_Focused_Viewer.ipynb)**

Stage 2D/2E の `hand_21_landmarks_long.csv` と Stage 2D の `release_zoom_175_210.mp4` を使い、188〜193フレームの **2D参照動画・画像原点疑似3D・手ローカル疑似3D・示指/中指/母指の2D投影角度グラフ**を時間スライダーで同期。投球手の左右は手動指定。静的HTML・比較MP4・代表PNG・品質CSV・ZIPをDriveに保存します。**世界座標系や実測3Dではなく、2D投影角は真の指関節屈伸角ではありません。**

## Stage 2F：3D Hand Skeleton Viewer（時間スライダー・360°回転）

[![Open Stage 2F in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2F_3D_Hand_Skeleton_Viewer.ipynb)

**[Stage 2FをColabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2F_3D_Hand_Skeleton_Viewer.ipynb)**

Stage 2D/2Eの`hand_21_landmarks_long.csv`を入力。**画像左上を原点とするXY固定座標（手首の画面内移動と軌跡を表示）＋手首相対Z**で21点の手指骨格を表示し、時間スライダー・マウス回転を操作できます。保存したHTMLではYaw/Pitch回転バーを使えます。代表フレームの横360°・縦360°回転MP4、PNG、共有用ZIPをGoogle Driveに出力します。**MediaPipeの相対Zによる疑似3D表示であり、実寸3Dや実測した背面画像ではありません。**

## Stage 2E：指先3点ハイライト動画（通常・スロー・左右比較）

[![Open Stage 2E in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2E_KeyTips_Showcase.ipynb)

**[Stage 2EをGoogle Colabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2E_KeyTips_Showcase.ipynb)**

195〜200フレームの母指・示指・中指先端を色分けし、通常速度・1/6速度・左右比較動画を生成。手動ROIは **x0, y0スライダー＋200×200 px固定正方形**。175/190/210フレームの初期位置は前回Stage 2D解析結果から入力済みです。座標CSVと研究プレビュー用ZIPをDriveに保存します。指先座標とGrabCutマスクは未検証の推定結果であり、離手時刻の自動検出ではありません。

## Stage 2D：動画提供者向けのリリース付近プレビュー

[![Open Stage 2D in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2D_Release_Showcase.ipynb)

**[Stage 2DをColabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2D_Release_Showcase.ipynb)**

指定フレーム区間を手動ROIで追跡し、Hand Landmarkerの21点2D骨格・GrabCut暫定マスク・元動画座標CSV・QC動画・動画提供者向けZIPをGoogle Driveに保存します。検出失敗フレームでは切り出し倍率を変えて再試行します。**手マスク・手の同一性・関節座標精度は未検証**であり、送付前に目視レビューと個人情報・共有許諾の確認が必要です。

## Stage 2C：手動ROIで手マスク＋21点骨格・CSV出力

[![Open Stage 2C in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2C_ManualROI_HandMask_Landmarks.ipynb)

**[Stage 2C：Colab Notebookを開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2C_ManualROI_HandMask_Landmarks.ipynb)**

- リリース前後の解析フレーム範囲を手動指定（例：175〜210）
- 3つのキーフレームでROIをスライダー確定し、中間ROIを線形補間
- MediaPipe Hand Landmarkerの**21点2D座標**を元動画のピクセル座標でCSV化
- ROIとランドマークを手掛かりとする**暫定GrabCut手マスク**をPNG保存
- 手マスク＋骨格の重畳MP4、拡大MP4、QC CSV/JSONをDriveへ保存

**重要**：この段階の手マスクは学習済みhand segmentationではなく、正確な輪郭を保証しません。21点はMediaPipeの2D点であり、WiLoRの公式カメラ投影ではありません。結果動画を目視してから研究利用してください。

## Stage 2B：手動アンカー＋前後双方向追跡＋21点QC

[![Open Stage 2B in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2B_Anchored_Tracking_21Landmarks.ipynb)

**[Stage 2B NotebookをColabで開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2B_Anchored_Tracking_21Landmarks.ipynb)**

任意のフレームで投球手のBOXを手動指定し、前後双方向に追跡。WiLoRの21点を暫定カメラ式で2Dに投影し、全フレーム重畳MP4・175〜210フレーム拡大MP4・追跡QCのCSV・NPZをGoogle Driveへ保存します。

**検証上の注意**：WiLoR公式パッチ前処理・カメラ投影に一致することは未確認です。21点は精度未検証の診断用表示であり、関節角度計測やリリース評価には使わないでください。

## Stage 2A：Pose誘導による投球手追跡

[![Open Stage 2A in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2A_Pose_Flow_WiLoR.ipynb)

**[Stage 2AのNotebookを開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage2A_Pose_Flow_WiLoR.ipynb)**

MediaPipe Poseの肩・肘・手首、YOLO/OpenVINO、Lucas–Kanade光学フローを組み合わせ、正しい投球手のROI候補を時系列で追跡します。WiLoR INT8の生出力とQC動画をDriveへ保存します。Pose由来の暫定ROIは正しい手の検出と同義ではありません。

## 使い方

1. 上のボタンからNotebookを開き、ColabのCPUランタイムを選択
2. Google Driveをマウント（共有フォルダ名：母指回内トラッキング）
3. Drive内の既存WiLoR・検出器モデルをローカルにコピーし、OpenVINOでコンパイル
4. 投球動画を選択
5. **全フレームの解析セル**を実行（STRIDE=1）
6. Google Drive内の `FingerBall_v2_stage1_results/full_video/` にCSV・NPZ・BOX動画・レポートを保存

## Stage 1の出力

- `frame_detection_results.csv`：解析したフレーム、手検出成否、BOX座標、WiLoR成否
- `wilor_predictions.npz`：WiLoR生テンソル（検出成功フレームのみ）
- `hand_detection_full_video.mp4`：BOX重畳動画（未検出フレームも含む）
- `stage1_full_video_report.json`：解析件数と設定

**制限**：OpenVINO CPU動作検証用です。21点関節座標、3D角度、ボール検出、リリースは未実装。推論の画像前処理は元のWiLoRアプリとの完全一致を検証していません。

## データの取り扱い

GitHubにはNotebook・ソースコードだけを保存します。モデルの重み、MANOファイル、投球動画、被験者情報、解析出力を公開リポジトリへアップロードしないでください。共有データを使用する場合は研究倫理と各モデルのライセンスを確認してください。
