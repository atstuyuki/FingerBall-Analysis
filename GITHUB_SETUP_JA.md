# GitHub新規作成手順

1. GitHubにログインし https://github.com/new を開く。
2. Ownerを `atstuyuki`、Repository nameを `FingerBall-Analysis` にする。
3. **Private** を選択して「Create repository」。README/ライセンスの自動初期化は不要（空リポジトリを作成）。
4. このZIPをPCで展開し、中の `README.md`、`.gitignore`、`LICENSE_NOTICE.md`、`GITHUB_SETUP_JA.md`、`notebooks/` フォルダをGitHubにアップロードする。フォルダ構造を保つ。
   - ブラウザの場合、`Add file` → `Upload files` から追加。サブフォルダが保持できない場合は Git クライアントを使用。
5. `main` ブランチでコミットされたら、READMEの「Open Stage 1 in Colab」をクリック。
6. Colab上でGoogle Driveのマウントを許可し、投球動画とモデルを指定する。

実際のGoogle Driveモデルは**GitHubにはアップロードしない**。リポジトリ名を変える場合はREADMEのColab URLも変更。
