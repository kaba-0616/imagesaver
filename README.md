# ImageSaver

Safariで表示中のWebページから画像を一括抽出して選択保存する、Safari Action Extension アプリです。
更新が止まった「ImageDrain」の代替として、個人利用向けに自作したものです。

Mac不要・Windowsだけでビルド〜インストールまで完結する構成になっています。

## 全体の流れ

1. このリポジトリをGitHubにpushする
2. GitHub Actions がクラウド上のMacで自動ビルドし、未署名の `ImageSaver.ipa` を作成する
3. Windows用ツール「Sideloadly」で、無料のApple IDを使いその場署名してiPhone/iPadにインストールする
4. Safariの設定で機能拡張を有効化する

Xcodeのインストールや操作は一切不要です。

---

## 1. GitHubにpushする

```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/<あなたのユーザー名>/imagesaver.git
git push -u origin main
```

Privateリポジトリで問題ありません(GitHub Actionsのビルドはprivateでも無料枠内で動作します)。

## 2. ビルドを実行する

pushすると自動的に `.github/workflows/build.yml` が実行されます。

1. GitHubのリポジトリページ → 「Actions」タブを開く
2. 実行中のワークフロー(「Build unsigned IPA」)をクリックし、完了(緑のチェック)を待つ(数分程度)
3. 失敗したら赤い ✕ が付くので、ログを開いてエラーメッセージをコピーし、相談してください
4. 成功したら、実行結果ページ下部の「Artifacts」から `ImageSaver-ipa` をダウンロードし、zipを展開すると `ImageSaver.ipa` が入っています

コードを修正したら、再度pushすれば自動的に再ビルドされます(`workflow_dispatch` にも対応しているので、Actionsタブから手動で「Run workflow」も可能です)。

## 3. Sideloadlyでインストールする

1. Windows PCに [Sideloadly](https://sideloadly.io/) をインストールする
2. iPhone/iPadをUSBケーブルでPCに接続する(初回は端末側で「このコンピュータを信頼しますか?」を許可)
3. Sideloadlyを起動し、iTunes/Apple Mobile Device Support が必要な場合は案内に従ってインストールする
4. Sideloadly画面に `ImageSaver.ipa` をドラッグ&ドロップする
5. Apple IDとパスワードの入力を求められたら、お使いの無料Apple IDでサインインする(2ファクタ認証のコード入力が必要な場合あり)
6. 「Start」でインストール開始。iPhone/iPadのホーム画面に「ImageSaver」アイコンが追加されます

### 初回起動時: 開発者を信頼する

インストール後にアプリを開こうとすると「信頼されていないデベロッパ」と表示されます。

「設定」→「一般」→「VPNとデバイス管理」→ 該当のApple IDのプロファイルを選択 →「信頼」をタップしてください。

### 無料Apple IDの制限について

- インストールしたアプリは **7日間で自動的に使えなくなります**
- 7日以内にSideloadlyで同じPCから再インストールしてください(自動再署名機能もあります。Sideloadlyの案内に従ってください)
- 年99ドルのApple Developer Programに登録すると、有効期限が1年に延びます

## 4. Safariの共有シートでImageSaverを有効にする

ImageSaverは「設定→Safari→機能拡張」に出てくるタイプの拡張機能ではなく、共有シートの**アクション**として動作します。初回だけ一覧に表示させる操作が必要です。

1. Safariで適当なページを開き、共有ボタン(□に↑のアイコン)をタップ
2. 一番下の並び(アイコンが横に並んだ列)を左端までスワイプし、「その他」をタップ
3. 「アクションを編集」画面で「ImageSaver」を探し、緑の「+」(または並び替えリストのスイッチ)をオンにする
4. 「完了」をタップ

これで以降、共有シートのアクション一覧に「ImageSaver」が表示されるようになります。

## 使い方

1. Safariで画像を保存したいページを開く
2. 共有ボタン(□に↑のアイコン)をタップ
3. アクション一覧から「ImageSaver」を選択(表示されない場合は上記「4.」の手順で有効化してください)
4. ページ内の画像がグリッド表示されるので、保存したい画像をタップして選択(チェックマーク)
5. 右上のフィルターアイコンで小さい画像(アイコン等)を除外可能
6. 「フルスクリーン」表示に切り替えると1枚ずつ大きく確認しながら選択できる
7. 下部の「保存する」をタップするとカメラロールに保存される

対応フォーマット: JPEG / PNG / GIF / HEIF(HEIC) / WebP / SVG(ラスタライズして保存)

トップ画面(ホーム画面のImageSaverアプリ)には、最近開いたページの履歴が表示され、タップするとSafariで再度そのページを開けます。

## 既知の制限・注意点

- 無料Apple IDは同一Apple IDで同時にインストールできるアプリ数・週あたりの登録App ID数に制限があります(通常の個人利用では問題になりません)
- CSSの `background-image` はページ内の要素数が多い場合、検出範囲を先頭4000要素までに制限しています(元アプリで報告されていた「大量画像で激重になる」問題を避けるための対策です)
- サムネイルは最大6並列、保存処理は最大4並列でダウンロードし、メモリを圧迫しないようにしています

## 開発メモ(コード変更時)

- `project.yml` を編集後、ローカルでの動作確認はできません(Windows環境のためXcodeが使えません)。pushしてGitHub Actionsのビルド結果で確認してください
- 主なフォルダ構成
  - `ImageSaverApp/` : コンテナアプリ(ホーム画面のアイコン、使い方説明、履歴表示)
  - `ImageSaverAction/` : Action Extension本体(画像抽出・グリッドUI・保存処理)
  - `Shared/` : 両方から使う共通コード(履歴の保存・読み込み)
