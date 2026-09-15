import SwiftUI
import GoogleMobileAds

/// A standard banner. One ad unit per placement (so AdMob's reporting can
/// tell them apart) -- see `AdUnit` below for the actual IDs.
struct AdBannerView: UIViewRepresentable {
    let adUnitID: String

    init(_ placement: AdUnit) {
        self.adUnitID = placement.id
    }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = adUnitID
        banner.rootViewController = context.environment.uiRootViewController
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

/// The real, AdMob-issued banner units for this app's placements.
enum AdUnit {
    case top
    case duplicateFinder
    case marginCrop
    case settings

    var id: String {
        switch self {
        case .top: return "ca-app-pub-1034383442757151/4861932057"
        case .duplicateFinder: return "ca-app-pub-1034383442757151/9922687045"
        case .marginCrop: return "ca-app-pub-1034383442757151/4909646477"
        case .settings: return "ca-app-pub-1034383442757151/8802759648"
        }
    }
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
