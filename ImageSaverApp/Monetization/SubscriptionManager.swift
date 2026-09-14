import Foundation
import StoreKit

/// The product identifier isn't real yet -- no subscription exists in App
/// Store Connect (that's a pricing/naming decision, not a code one; see
/// docs/monetization-todo.md). Kept as a single named constant so the one
/// place this needs to change, once a real product exists, is here.
enum SubscriptionProduct {
    static let monthlyID = "jp.kaba.imagesaverv2.subscription.monthly"
    static let allIDs: Set<String> = [monthlyID]
}

/// Purchase, restore, and "is the user currently entitled" -- the three
/// things StoreKit 2 needs for a subscription regardless of what the
/// subscription unlocks. What it unlocks (hiding ads? something else?) is
/// deliberately not this type's business; callers read `isSubscribed`.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var isSubscribed = false
    @Published private(set) var products: [Product] = []

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
        do {
            products = try await Product.products(for: SubscriptionProduct.allIDs)
        } catch {
            // Not fatal: an empty `products` array just means any paywall
            // UI has nothing to list, same as "not configured yet".
            products = []
        }
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
        var subscribed = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if SubscriptionProduct.allIDs.contains(transaction.productID) {
                subscribed = true
            }
        }
        isSubscribed = subscribed
    }
}
