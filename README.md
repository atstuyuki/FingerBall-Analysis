# FingerBall Analysis v2

単眼投球動画から手指の動きを解析するプロジェクトです。**Stage 1は全フレームの手検出とWiLoR INT8の生テンソル保存**まで対応しています。

[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)

**[Google ColabでStage 1を開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)**

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
