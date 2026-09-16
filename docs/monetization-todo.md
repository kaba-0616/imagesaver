# 収益化: 残タスク(ユーザー対応が必要なもの)

2026-09-15、コードで完結する部分(build186)は実装済み。以下はアカウント
作成・ビジネス判断が絡むため、意図的にスキップした/プレースホルダのまま
にしてある項目。

## 広告(AdMob) -- 2026-09-15、実アカウント作成・組み込み完了

- AdMobアカウント作成済み。アプリID・3箇所ぶんの広告ユニットIDも発行済みで、
  `project.yml`(`GADApplicationIdentifier`)と`AdBannerView.swift`
  (`AdUnit` enum)に実際の値を反映済み(build188〜)。テストIDは残っていない。
- 掲出箇所はTOP画面・重複整理画面・余白整理画面・設定画面の4箇所、それぞれ
  専用の広告ユニットで実装済み(`ContentView`/`DuplicateFinderView`/
  `MarginCropFinderView`/`SettingsView`、いずれもリスト下部にバナー1枠)。
- 設定画面用の広告ユニット(`AdUnit.settings`、`ca-app-pub-1034383442757151/
  8802759648`)も発行・反映済み(2026-09-15、build194〜)。テストIDは
  残っていない。
- 機密カテゴリ(性描写への言及・性と生殖に関する健康・出会い系・水着)は
  AdMob管理画面の「ブロック管理」からブロック設定済み。
- **SKAdNetworkItems完全一覧、追加済み(2026-09-15、build192〜)。**
  https://developers.google.com/admob/ios/privacy/strategies から
  Google自身のIDを含む50件を取得し`project.yml`に反映。一覧は随時
  更新されるため、次に見直す際は同じページから再取得して差分を確認する
  こと。
- **リワード広告(削除回数回復)追加済み(2026-09-15、build189〜)。**
  重複整理の「削除」に1日20枚までの無料上限(`ActionQuota`)を設け、
  超えるとAdMobのリワード広告(ユニット名「削除回数回復リワード」、
  `ca-app-pub-1034383442757151/5458109681`)を見ると+20枚回復する。
  `RewardedAdManager.swift`/`ActionQuota.swift`(いずれも
  `ImageSaverApp/Monetization/`)を参照。MarginCrop側は現状写真を
  一切編集しない(候補を探すだけ)ため、このカウントの対象外。

## サブスクリプション

**仕様確定済み(2026-09-15)。** 1つのサブスクリプショングループに2プラン:
- **Lite**: 広告非表示のみ。
- **Full**: 広告非表示 + 削除回数無制限(`ActionQuota`を完全バイパス)。

`SubscriptionManager.swift`(`SubscriptionTier` enum・`isAdsRemoved`/
`isUnlimitedDeletes`)、`ContentView`/`DuplicateFinderView`/
`MarginCropFinderView`(いずれもプラン加入中はバナー非表示)、
`DuplicateFinderView`の削除処理(Fullプラン中は`ActionQuota`を参照しない)
まで実装済み(build190〜見込み)。

- **App Store Connect側の作成は完了(2026-09-15)。** サブスクリプション
  グループ「ImageSaver Plus」の中に、Full Monthly
  (`jp.kaba.imagesaverv2.subscription.full.monthly`、表示名
  「ImageSaver Full」)・Lite Monthly
  (`jp.kaba.imagesaverv2.subscription.lite.monthly`、表示名
  「ImageSaver Lite」)を作成済み。価格・配信状況・ローカリゼーション
  (商品/グループ両方)とも設定済み。コード側のプレースホルダIDと実際の
  製品IDが完全一致しているため、`SubscriptionManager.swift`の修正は
  不要だった。
- **ペイウォールUI実装済み(2026-09-15、build191〜)。**
  `PaywallView.swift`(新規)が`SubscriptionManager.products`から
  Full/Liteを一覧表示し(価格・説明はStoreKitから取得、Full優先で表示)、
  「登録する」/「このプランに切り替える」ボタンで購入、現在のプランには
  チェックマークを表示する。`ContentView`の「購入状況」セクションに
  「プランを見る」のNavigationLinkから遷移する。
- **原因判明(2026-09-16、build204): 審査提出前はTestFlightでも商品が
  取得できない。** ペイウォールで「サブスクリプション商品が見つかり
  ませんでした」を確認(`Product.products(for:)`が例外を投げず空配列を
  返す状態、商品ID・Bundle IDは一致しているため設定ミスではない)。
  Appleの既知の仕様として、新規のサブスク/App内課金は**承認される
  必要はないが、一度「審査に提出」した実績が無いとTestFlightの
  Sandbox環境でもStoreKitが商品情報を返さない**。このため、当初の
  想定(購入フロー確認→審査提出)とは順序が逆で、**審査提出が先、
  購入フロー確認はその後**になる。
- **残タスク:** 審査提出(「審査用に追加」)。App Store Connect側の
  グループ・2商品(Full/Lite)の作成・価格・ローカリゼーションは完了済み。
- **開発者本人へのFullプラン恒久付与(2026-09-15、方針確定・審査後に対応)。**
  Apple公式の「Offerコード」(サブスクの無料引き換えコード、App Store
  Connectの該当サブスク商品ページから発行)で対応する方針で確定した
  (TestFlight継続利用・個人用サイドロードビルドの2案も検討したが、
  本番のストアアプリをそのまま使える点を優先しOfferコードを選択)。コードに
  バックドアを仕込む方式は審査ガイドライン3.1.1違反のリスクがあるため
  採用しない。Offerコードは対象商品が一度審査を通過した後でないと
  発行できない可能性が高いため、初回審査提出・承認後に改めて発行する。
  期間は最長でも1年程度(無期限コードは無い)なので、実質「年1回、
  無料で再発行する」運用になる見込み。それまではTestFlight
  (Sandbox環境、購入は常に無料)で代用できる。
- ローカルでのStoreKitテストをXcodeで行いたい場合、
  `ImageSaverApp/Monetization/Subscriptions.storekit`(Lite/Fullの2商品を
  プレースホルダ価格で用意済み)をスキームの「Run」→「Options」→
  「StoreKit Configuration」で手動設定すると、実際のApp Store Connect
  商品が無くてもシミュレータで購入フローを試せる(project.yml側では未設定
  -- CIの`xcodegen generate`を壊すリスクを避けるため、意図的に手動設定の
  ままにしてある)。

## App Store Connect側の申請情報

- **年齢レーティング質問票、回答完了(2026-09-15)。** 算出結果は4+。
- **App Privacyラベル、記入・公開完了(2026-09-15)。** デバイスID・
  広告データ(いずれもサードパーティ広告/アナリティクス目的、トラッキング
  目的あり、ユーザー個人情報とは非紐付け)を申告。
- **プライバシーポリシー・サポートページ、公開完了(2026-09-15)。**
  GitHub Pages(`gh-pages`ブランチ)でホスティング:
  https://kaba-0616.github.io/imagesaver/privacy.html ・
  https://kaba-0616.github.io/imagesaver/support.html 。
  App Store Connectの「アプリのプライバシー」(プライバシーポリシーURL)・
  バージョンページの「App情報」(サポートURL)両方に登録済み。
  問い合わせ先は`imagesaver.support@gmail.com`(プライベートのGmailとは
  別に用意)。
- 銀行口座情報の登録(収益受け取りに必須、AdMob支払い最低額¥8,000到達前に)。
- 税務情報(W-8BEN、日米租税条約0%)・AdMob支払いプロフィールの電話番号は
  登録完了済み(2026-09-15)。
- **EU DSA(デジタルサービス法)のトレーダー申告、対応完了(2026-09-16)。**
  EU圏での配信は不要のため、(1)「価格および配信状況」でEU加盟国を
  配信対象から除外し、(2)申告ダイアログで「DSAに基づくトレーダーでは
  ありません、またはEU内で配信する予定はありません」を選択済み。
  住所・電話番号等をApp Storeページに公開する必要は無い。
  なお「契約、税金、口座情報」ページの「無料アプリ契約」「有料アプリ契約」
  はいずれも「有効」を確認済み(2026-09-16)。

## UI不具合修正(2026-09-16、build196〜203、実機確認OK)

- 重複/類似フルスクリーンのタップでチロム(上下バー)非表示(build196)。
- 設定画面リファクタ: 使い方・アクセス許可・購入関連をSettingsViewへ移動、
  TOP画面に専用の広告バナー枠を追加(build194/195)。
- 削除確認ダイアログが吹き出し(ポップオーバー)状に出る不具合を
  `.confirmationDialog`→`.alert`へ変更して修正(build197)。
- 照合し直し中のオーバーレイがナビゲーションバーのツールバーアイコンを
  覆えず浮いて見える不具合を、`.fullScreenCover`によるモーダル提示化で
  修正(build201。build198/199の`.toolbarBackground`方式はコンパイル
  エラーで断念、build200で一旦revert)。
- フルスクリーンのピンチズームでパン範囲に上限が無く、端まで寄せても
  画面縁に届かない不具合を`clampedPan`で修正(build202)。この修正で
  `currentPhoto`をGeometryReaderで包んだ副作用として画像が上寄りになる
  regressionが発生し、build203で明示的なフレーム指定により解消。

すべて実機確認OK(2026-09-16)。

## 参考

- 収益化の検討経緯全体は[[imagesaver-monetization-consideration]]
  (メモリファイル)を参照。
- 3uTools→TestFlight移行の経緯は[[imagesaver-testflight-setup]]
  (メモリファイル)を参照。
