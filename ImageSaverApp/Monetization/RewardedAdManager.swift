import Foundation
import GoogleMobileAds
import UIKit

/// Loads and shows the rewarded ad that refills `ActionQuota`. Kept
/// completely separate from `AdsManager`/`AdBannerView` (banners) -- a
/// rewarded ad has its own load/present lifecycle and its own ad unit type
/// in AdMob, not just another placement of the same banner unit.
@MainActor
final class RewardedAdManager: NSObject, ObservableObject {
    static let shared = RewardedAdManager()

    // Real AdMob rewarded ad unit ("削除回数回復リワード"), created 2026-09-15.
    private static let adUnitID = "ca-app-pub-1034383442757151/5458109681"

    @Published private(set) var isReady = false
    private var isLoading = false
    private var ad: RewardedAd?

    private override init() {
        super.init()
    }

    /// Safe to call repeatedly (e.g. every time the quota screen appears) --
    /// a load already in flight or an ad already held is left alone.
    func load() {
        guard ad == nil, !isLoading else { return }
        isLoading = true
        RewardedAd.load(with: Self.adUnitID, request: Request()) { [weak self] loadedAd, error in
            guard let self else { return }
            self.isLoading = false
            if let error {
                PhotoScanLog.shared.note("リワード広告読み込み失敗: \(error.localizedDescription)")
                return
            }
            self.ad = loadedAd
            self.ad?.fullScreenContentDelegate = self
            self.isReady = true
        }
    }

    /// Presents the loaded ad. `onReward` only fires from the SDK's own
    /// reward callback -- dismissing early or a presentation failure must
    /// never grant the bonus.
    func show(onReward: @escaping () -> Void) {
        guard let ad, let root = Self.rootViewController() else { return }
        ad.present(from: root) {
            onReward()
        }
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }?.rootViewController
    }
}

extension RewardedAdManager: FullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        self.ad = nil
        isReady = false
        load()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        PhotoScanLog.shared.note("リワード広告の表示に失敗: \(error.localizedDescription)")
        self.ad = nil
        isReady = false
        load()
    }
}
