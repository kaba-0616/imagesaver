# 収益化: 残タスク(ユーザー対応が必要なもの)

2026-09-15、コードで完結する部分(build186)は実装済み。以下はアカウント
作成・ビジネス判断が絡むため、意図的にスキップした/プレースホルダのまま
にしてある項目。

## 広告(AdMob) -- 2026-09-15、実アカウント作成・組み込み完了

- AdMobアカウント作成済み。アプリID・3箇所ぶんの広告ユニットIDも発行済みで、
  `project.yml`(`GADApplicationIdentifier`)と`AdBannerView.swift`
  (`AdUnit` enum)に実際の値を反映済み(build188〜)。テストIDは残っていない。
- 掲出箇所はTOP画面・重複整理画面・余白整理画面の3箇所、それぞれ専用の
  広告ユニットで実装済み(`ContentView`/`DuplicateFinderView`/
  `MarginCropFinderView`、いずれもリスト下部にバナー1枠)。
- 機密カテゴリ(性描写への言及・性と生殖に関する健康・出会い系・水着)は
  AdMob管理画面の「ブロック管理」からブロック設定済み。
- **残タスク:** `project.yml`の`SKAdNetworkItems`に、Googleが公開している
  **参加バイヤー企業の完全なID一覧**を追加する(現在はGoogle自身のID1つの
  み)。一覧は https://developers.google.com/admob/ios/privacy/strategies
  に随時更新されるため、実装時点でここから取得すること。
- インタースティシャル広告等、追加の広告フォーマットを増やすかは未検討
  (現状バナーのみ)。

## サブスクリプション

- App Store Connectで**サブスクリプショングループ・商品の作成**
  (価格・名称・説明文の決定はビジネス判断)。
- 商品作成後、`ImageSaverApp/Monetization/SubscriptionManager.swift`の
  `SubscriptionProduct.monthlyID`(現在プレースホルダ
  `jp.kaba.imagesaverv2.subscription.monthly`)を実際のProduct IDに
  合わせる。
- **サブスクで何が変わるか**(広告非表示なのか、別の付加機能なのか)が
  未確定。現状`SubscriptionManager.isSubscribed`は公開されているだけで、
  どこからも参照されていない(意図的に空けてある)。
- 実際のペイウォールUI(購入ボタンを含む画面)は未実装。現状TOP画面には
  「購入を復元」ボタンのみ置いてある(App Review Guideline 3.1.1対応の
  ため、ペイウォールが無くてもこれだけは先に用意した)。
- ローカルでのStoreKitテストをXcodeで行いたい場合、
  `ImageSaverApp/Monetization/Subscriptions.storekit`をスキームの
  「Run」→「Options」→「StoreKit Configuration」で手動設定すると、実際の
  App Store Connect商品が無くてもシミュレータで購入フローを試せる
  (project.yml側では未設定 -- CIの`xcodegen generate`を壊すリスクを
  避けるため、意図的に手動設定のままにしてある)。

## App Store Connect側の申請情報

- **年齢レーティング質問票**への回答(画面UIのみ、API無し)。
- **App Privacyラベル**(収集データの申告) -- 広告SDK追加後は申告内容が
  増える(IDFA・広告データ等)ので、AdMob設定が固まってから記入するのが
  安全。
- プライバシーポリシー・サポートページの実際のホスティングと内容確定。
- 税務・銀行口座情報の登録(収益受け取りに必須)。

## 参考

- 収益化の検討経緯全体は[[imagesaver-monetization-consideration]]
  (メモリファイル)を参照。
- 3uTools→TestFlight移行の経緯は[[imagesaver-testflight-setup]]
  (メモリファイル)を参照。
