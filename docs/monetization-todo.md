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
- **残タスク:** 設定画面用の広告ユニット(`AdUnit.settings`)はまだ
  Googleのテストバナー用プレースホルダIDのまま(2026-09-15、build194〜)。
  AdMobで「設定画面バナー」という名前でバナーユニットを新規作成し、
  発行されたIDを`AdBannerView.swift`の`AdUnit.settings`に反映すること。
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
- **残タスク:** 審査提出(「審査用に追加」)。App Store Connect側の
  グループ・2商品(Full/Lite)の作成・価格・ローカリゼーションは完了済み
  (製品IDがコードのプレースホルダと完全一致していたため差し替え不要
  だった)。ペイウォールUIも揃ったので、次は実機/TestFlightでの購入
  フロー確認 → 審査提出の順で進められる。
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

## 参考

- 収益化の検討経緯全体は[[imagesaver-monetization-consideration]]
  (メモリファイル)を参照。
- 3uTools→TestFlight移行の経緯は[[imagesaver-testflight-setup]]
  (メモリファイル)を参照。
