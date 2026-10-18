# FingerBall Analysis v2

投球動画の握球〜ボールリリースまでの手指運動解析プロジェクト。Stage 1 は Google Drive 上の WiLoR-mini INT8 (OpenVINO) と手検出器の読み込み、および1フレーム推論の動作検証です。

[![Open Stage 1 in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb)

**このボタンは `atstuyuki/FingerBall-Analysis` という名前のリポジトリを `main` ブランチで作成し、本ファイルを配置した後に動作します。** 別の名前にする場合はURLを修正してください。プライベートリポジトリでは GitHub の認証が必要な場合があります。

## 操作

1. [Colabを開く](https://colab.research.google.com/github/atstuyuki/FingerBall-Analysis/blob/main/notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb) をクリック（GitHub登録後）。
2. ColabでCPUランタイムを選択し、上からセルを実行。
3. 自分のGoogleアカウントでDriveをマウント。`PROJECT_DIR` にモデルがあるDriveのパスを指定する（Notebook側で名称検索も可能）。
4. 動画1本を指定・アップロードし、1フレームで手検出とWiLoRの生出力を確認。

## 重要

- **研究データ、動画、参加者情報、学習済み重み、MANOライセンスファイルはGitHubにコミットしない。** Google Drive（アクセス制限付き）に保管してください。
- この段階のOpenVINOモデルはColabのCPUで動かします。NVIDIA CUDAを利用するPyTorch版WiLoRは次段階で別途構築します。
- 既存の母指回内角研究ではモデルやMANOの再配布制限があるため、公開リポジトリへの追加は避けます。
- Stage 1はモデルのロード・推論検証が目的で、21点関節座標の復元やボール接触・リリース検出は未実装です。
- 元コードの動作をColabで再現できたことを保証するものではありません。

## Files

- `notebooks/FingerBall_v2_Stage1_Drive_WiLoR_OpenVINO.ipynb`: Stage 1 Colab Notebook
- `.gitignore`: 大容量・機微データをGit管理対象から除外
- `LICENSE_NOTICE.md`: 第三者モデルの扱いに関する注意
