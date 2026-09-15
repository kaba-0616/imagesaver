import StoreKit
import SwiftUI

/// The screen App Review Guideline 3.1.1 assumes exists once a subscription
/// is purchasable -- lists both plans (Lite/Full) with their real
/// StoreKit-reported price and lets the user buy or switch. "購入を復元" on
/// `ContentView` stays separate; that one has to work even when this screen
/// (or the App Store Connect products behind it) is unreachable.
struct PaywallView: View {
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(sortedProducts, id: \.id) { product in
                    planRow(product)
                }
                if subscriptions.isLoadingProducts {
                    Text("プランを読み込んでいます…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text("サブスクリプションは自動更新されます。いつでも「設定」アプリの自分のApple IDからキャンセルできます。")
            }
            // Distinct from `isLoadingProducts` above -- this is what shows
            // once the fetch has actually finished and still came back
            // empty/erroring, which used to be indistinguishable from
            // "still loading" and looked like it never finished at all.
            if let loadError = subscriptions.loadError {
                Section {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("プランを選ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscriptions.loadProducts() }
    }

    /// Full first: the higher plan is the one worth leading with, and it
    /// matches the "降順" ordering App Store Connect's own group screen uses.
    private var sortedProducts: [Product] {
        subscriptions.products.sorted { lhs, rhs in
            SubscriptionProduct.tier(for: lhs.id) == .full
        }
    }

    private func planRow(_ product: Product) -> some View {
        let tier = SubscriptionProduct.tier(for: product.id)
        let isCurrent = subscriptions.tier == tier
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayName)
                    .font(.headline)
                Spacer()
                Text(product.displayPrice)
                    .font(.subheadline.weight(.semibold))
            }
            Text(product.description)
                .font(.footnote)
                .foregroundColor(.secondary)
            if isCurrent {
                Label("現在のプラン", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.top, 2)
            } else {
                Button(subscriptions.tier == nil ? "登録する" : "このプランに切り替える") {
                    Task { await purchase(product) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurchasing)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func purchase(_ product: Product) async {
        isPurchasing = true
        errorMessage = nil
        do {
            try await subscriptions.purchase(product)
        } catch {
            errorMessage = "購入できませんでした: \(error.localizedDescription)"
        }
        isPurchasing = false
    }
}
