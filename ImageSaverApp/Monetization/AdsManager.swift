import Foundation
import AppTrackingTransparency
import GoogleMobileAds

/// Owns the two steps that have to happen before an ad can show: asking for
/// tracking permission (ATT), then starting the SDK. Neither can be skipped
/// or reordered -- starting the SDK before the ATT prompt has been resolved
/// is what the SDK's own docs warn locks personalized ads off for the rest
/// of the session, and the prompt itself requires an already-visible window
/// to attach to, so this can't just run from App.init().
@MainActor
final class AdsManager: ObservableObject {
    static let shared = AdsManager()

    @Published private(set) var isReady = false

    private init() {}

    /// Call once, after the first view has appeared (so ATT has a window to
    /// present from). Safe to call more than once -- only the first call
    /// does anything.
    func start() {
        guard !isReady else { return }
        Task {
            // A denied/restricted/not-yet-determined status all still let
            // the SDK start -- ads just come back non-personalized. Only a
            // genuinely undetermined status gets a prompt at all; asking
            // again after the user has already answered would be a no-op
            // (iOS just returns the stored answer instantly) but there's no
            // reason to invoke the API twice.
            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                _ = await ATTrackingManager.requestTrackingAuthorization()
            }
            MobileAds.shared.start { [weak self] _ in
                self?.isReady = true
            }
        }
    }
}
