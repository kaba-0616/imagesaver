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

- **残タスク:** App Store Connectで**実際のサブスクリプショングループ・
  2商品(Lite/Full)の作成**(価格・表示名の決定はビジネス判断)。
  作成後、`SubscriptionManager.swift`の`SubscriptionProduct.
  liteMonthlyID`/`fullMonthlyID`(現在プレースホルダ
  `jp.kaba.imagesaverv2.subscription.lite.monthly`/`.full.monthly`)を
  実際のProduct IDに合わせる。
- 実際のペイウォールUI(2プランを比較して選んで購入する画面)は未実装。
  現状TOP画面には「購入を復元」ボタンと現在のプラン表示のみ置いてある
  (App Review Guideline 3.1.1対応のため、ペイウォールが無くてもこれだけ
  は先に用意した)。
- ローカルでのStoreKitテストをXcodeで行いたい場合、
  `ImageSaverApp/Monetization/Subscriptions.storekit`(Lite/Fullの2商品を
  プレースホルダ価格で用意済み)をスキームの「Run」→「Options」→
  「StoreKit Configuration」で手動設定すると、実際のApp Store Connect
  商品が無くてもシミュレータで購入フローを試せる(project.yml側では未設定
  -- CIの`xcodegen generate`を壊すリスクを避けるため、意図的に手動設定の
  ままにしてある)。

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
