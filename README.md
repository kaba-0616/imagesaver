# ImageSaver

Safariで表示中のWebページから画像を一括抽出して選択保存する、Safari Action Extension アプリです。
更新が止まった「ImageDrain」の代替として、個人利用向けに自作したものです。

Mac不要・Windowsだけでビルド〜インストールまで完結する構成になっています。

## 全体の流れ

1. このリポジトリをGitHubにpushする
2. GitHub Actions がクラウド上のMacで自動ビルドし、未署名の `ImageSaver.ipa` を作成する
3. **AltStore** で、無料のApple IDを使いその場署名してiPhone/iPadにインストールする
4. Safariの共有シートでImageSaverを有効化する

Xcodeのインストールや操作は一切不要です。

> **重要: Sideloadlyは使わないこと**
> Sideloadly(v0.60時点)はiOS 26の拡張機能の署名に対応しておらず、アプリ本体は起動できても
> 共有シートから拡張機能を呼び出した瞬間に `CODESIGNING / Invalid Page` で強制終了します
> (クラッシュログすら残らないこともある)。AltStoreを使えば正常に動作します。

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

## 3. AltStoreでインストールする

### 初回のみ: AltServer / AltStore のセットアップ

1. [Apple公式サイト](https://www.apple.com/itunes/)からiTunesとiCloudをインストールする
   (**Microsoft Store版では動作しない**。既にStore版が入っている場合はアンインストールしてから入れ直す)
2. [AltServer](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) をダウンロードし、`AltInstaller.zip` を展開して `AltInstaller.msi` を実行
3. iPhoneをUSB接続し、iTunesを開いて **「Wi-Fi経由でこのiPhoneと同期」にチェックを入れて「適用」**
   (これを忘れると `AltServer could not find this device` エラーになる)
4. タスクバー通知領域のAltServerアイコンを**左クリック**(右クリックではない)→「Install AltStore」→ 端末を選択
5. Apple IDとパスワードを入力
6. iPhone側「設定」→「一般」→「VPNとデバイス管理」→ プロファイルを「信頼」

### ipaをインストールする

1. `ImageSaver.ipa` をPCの **iCloud Drive** フォルダにコピーする(iPhoneから見えるようにするため)
2. iPhoneでAltStoreアプリを開き、「My Apps」タブ → 左上の「+」
3. iCloud Driveから `ImageSaver.ipa` を選択
4. **「App Contains Extensions」と聞かれたら必ず「Keep App Extensions」を選ぶ**
   (「Remove App Extensions」を選ぶと肝心の拡張機能が入らない)
5. インストール完了を待つ

### 無料Apple IDの制限について

- インストールしたアプリは **7日間で自動的に使えなくなります**
- AltStoreはPCでAltServerが起動していて同じWi-Fiにいれば、バックグラウンドで自動的に再署名(リフレッシュ)してくれます
- 年99ドルのApple Developer Programに登録すると、有効期限が1年に延びます

## 4. Safariの共有シートでImageSaverを有効にする

ImageSaverは「設定→Safari→機能拡張」に出てくるタイプの拡張機能ではなく、共有シートの**アクション**として動作します。初回だけ一覧に表示させる操作が必要です。

1. Safariで適当なページを開き、共有ボタン(□に↑のアイコン)をタップ
2. 一番下の並び(アイコンが横に並んだ列)を左端までスワイプし、「その他」をタップ
3. 「アクションを編集」画面で「ImageSaver」を探し、緑の「+」(または並び替えリストのスイッチ)をオンにする
4. 「完了」をタップ

これで以降、共有シートのアクション一覧に「ImageSaver」が表示されるようになります。

## 5. 写真への保存を許可する(初回のみ・必須)

**インストール後、最初に必ずこの操作をしてください。**

1. ホーム画面の「ImageSaver」アプリを開く
2. 「必要な許可」の「**写真への保存を許可する**」をタップ
3. 「許可」を選び、表示が「許可済み」になることを確認

> iOS 26では、共有シートの拡張機能から写真アクセスの許可ダイアログを出そうとすると
> 拡張機能が強制終了してしまいます(画面が一瞬で閉じる)。そのため、許可はコンテナアプリ側で
> 事前に済ませておく必要があります。

## 使い方

1. Safariで画像を保存したいページを開く
2. 共有ボタン(□に↑のアイコン)をタップ
3. アクション一覧から「ImageSaver」を選択(表示されない場合は上記「4.」の手順で有効化してください)
4. ページ内の画像がグリッド表示されるので、保存したい画像をタップして選択(チェックマーク)
5. 右上のフィルターアイコンで「小を除外」(250px未満)「中・小を除外」(700px未満)の絞り込みができる。判定にはダウンロード後の実寸を使うため、タイルに表示されているサイズと一致する
6. ページが表示していない画像(高解像度の原本や、カルーセルの未表示分)が見つかった場合、下部に「ソース内 +N」ボタンが出るのでタップすると一覧に追加される。インスタなど、無関係な投稿の画像が混ざることがあるため既定では非表示にしている
7. 「フルスクリーン」表示に切り替えると1枚ずつ大きく確認しながら選択できる(左右スワイプで送り、上下スワイプでグリッドに戻る)
8. 下部の「保存する」をタップするとカメラロールに保存される

対応フォーマット: JPEG / PNG / GIF / HEIF(HEIC) / WebP / SVG(ラスタライズして保存)

## 既知の制限・注意点

- 無料Apple IDは同一Apple IDで同時にインストールできるアプリ数・週あたりの登録App ID数に制限があります(通常の個人利用では問題になりません)
- CSSの `background-image` はページ内の要素数が多い場合、検出範囲を先頭4000要素までに制限しています(元アプリで報告されていた「大量画像で激重になる」問題を避けるための対策です)
- サムネイルは最大6並列、保存処理は最大4並列でダウンロードし、メモリを圧迫しないようにしています

## 開発メモ(コード変更時)

- `project.yml` を編集後、ローカルでの動作確認はできません(Windows環境のためXcodeが使えません)。pushしてGitHub Actionsのビルド結果で確認してください
- 主なフォルダ構成
  - `ImageSaverApp/` : コンテナアプリ(ホーム画面のアイコン、使い方説明)
  - `ImageSaverAction/` : Action Extension本体(画像抽出・グリッドUI・保存処理)
  - `Shared/` : 両方から使う共通コード
