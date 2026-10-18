# FingerBall Analysis v2

単眼投球動画から手指の動きを解析するプロジェクトです。**Stage 1は全フレームの手検出とWiLoR INT8の生テンソル保存**まで対応しています。

[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)

**[Google ColabでStage 1を開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)**

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
