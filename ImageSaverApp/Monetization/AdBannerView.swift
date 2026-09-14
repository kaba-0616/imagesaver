import SwiftUI
import GoogleMobileAds

/// A standard banner. Kept to a single reusable view so there is exactly one
/// place to swap the test ad unit ID for a real one later, rather than a
/// string duplicated at every call site.
struct AdBannerView: UIViewRepresentable {
    // Google's official test banner unit -- always serves a clearly-labelled
    // test creative, safe to ship. Swap for a real ad unit ID once AdMob
    // account setup exists; see docs/monetization-todo.md.
    private static let testAdUnitID = "ca-app-pub-3940256099942544/2934735716"

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = Self.testAdUnitID
        banner.rootViewController = context.environment.uiRootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

/// SwiftUI has no built-in way to hand a UIViewController to a
/// UIViewRepresentable; AdMob needs one (to present click-through sheets
/// and interstitials from) so this reaches it the same way one would from
/// UIKit -- via the active window scene's key window.
private struct UIRootViewControllerKey: EnvironmentKey {
    static let defaultValue: UIViewController? = {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }?.rootViewController
    }()
}

private extension EnvironmentValues {
    var uiRootViewController: UIViewController? {
        self[UIRootViewControllerKey.self]
    }
}
