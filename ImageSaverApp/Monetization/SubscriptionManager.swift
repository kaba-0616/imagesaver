import Foundation
import StoreKit

/// Two plans in one subscription group, so a subscriber can upgrade/downgrade
/// between them without StoreKit treating it as cancel-and-rebuy. Neither
/// product ID is real yet -- no subscription exists in App Store Connect
/// (pricing/naming is a business decision, not a code one; see
/// docs/monetization-todo.md). Kept as named constants so the one place
/// these need to change, once real products exist, is here.
enum SubscriptionProduct {
    static let liteMonthlyID = "jp.kaba.imagesaverv2.subscription.lite.monthly"
    static let fullMonthlyID = "jp.kaba.imagesaverv2.subscription.full.monthly"
    static let allIDs: Set<String> = [liteMonthlyID, fullMonthlyID]

    static func tier(for productID: String) -> SubscriptionTier? {
        switch productID {
        case liteMonthlyID: return .lite
        case fullMonthlyID: return .full
        default: return nil
        }
    }
}

/// What each plan actually unlocks. `full` is a strict superset of `lite`
/// (ads removed either way, unlimited deletes only on `full`) -- callers
/// that only care about one entitlement should read `isAdsRemoved`/
/// `isUnlimitedDeletes` rather than switching on this directly.
enum SubscriptionTier {
    case lite
    case full
}

/// Purchase, restore, and "is the user currently entitled, to which plan" --
/// the things StoreKit 2 needs for a subscription regardless of what each
/// plan unlocks.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var tier: SubscriptionTier?
    @Published private(set) var products: [Product] = []

    /// `products.isEmpty` alone can't tell "still fetching" apart from "the
    /// fetch already finished and came back empty/errored" -- the paywall
    /// showed "読み込んでいます…" forever in both cases until this was added,
    /// which made a real, immediately-returned error indistinguishable from
    /// still waiting on it.
    @Published private(set) var isLoadingProducts = true
    @Published private(set) var loadError: String?

    /// Ads are hidden on both plans.
    var isAdsRemoved: Bool {
        return tier != nil
    }
    /// Only the higher plan bypasses `ActionQuota`.
    var isUnlimitedDeletes: Bool { tier == .full }
    /// Kept for the existing "購入状況" row and Restore Purchases flow, which
    /// only need to know "is anything active", not which plan.
    var isSubscribed: Bool { tier != nil }

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Transaction.updates delivers renewals, refunds, and Ask-to-Buy
        // approvals that happen while the app isn't the one driving the
        // purchase (e.g. it was backgrounded) -- entitlement can change
        // without any call this type made, so this has to run for the
        // process's whole lifetime, not just around purchase().
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        isLoadingProducts = true
        loadError = nil
        do {
            let fetched = try await Product.products(for: SubscriptionProduct.allIDs)
            products = fetched
            // `Product.products(for:)` silently drops IDs it can't resolve
            // instead of throwing -- an empty result here is exactly what
            // "the Paid Apps Agreement/product isn't actually live yet"
            // looks like, and previously was indistinguishable from a
            // genuine network failure.
            if fetched.isEmpty {
                loadError = "サブスクリプション商品が見つかりませんでした。App Store Connect側の設定がまだ反映されていない可能性があります。"
            }
        } catch {
            // Not fatal: an empty `products` array just means any paywall
            // UI has nothing to list, same as "not configured yet".
            products = []
            loadError = "商品の読み込みに失敗しました: \(error.localizedDescription)"
        }
        isLoadingProducts = false
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            await handle(verification)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    /// For the App Store's required "Restore Purchases" affordance -- a
    /// reinstall or a new device has no local record of what was bought,
    /// only the App Store account does.
    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = update else {
            // Unverified means StoreKit couldn't validate the JWS signature
            // -- treat it as if the purchase never happened rather than
            // grant access on unverified say-so.
            return
        }
        await transaction.finish()
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        var active: SubscriptionTier?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let found = SubscriptionProduct.tier(for: transaction.productID) else { continue }
            // Only one plan in the group should ever be active at once, but
            // if a plan-switch transition briefly surfaces both, prefer the
            // higher one rather than whichever the loop happened to see last.
            if found == .full || active == nil {
                active = found
            }
        }
        tier = active
    }
}
