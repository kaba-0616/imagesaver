import Foundation

/// A shared "how many destructive actions can I still do today" budget.
///
/// Currently the only action that spends from it is `DuplicateFinderView`'s
/// delete -- MarginCrop never edits a photo itself (see `MarginCropScanner`'s
/// header comment: it stopped short of cropping and only marks candidates),
/// so it has nothing destructive to gate yet. This stays a single shared pool
/// rather than one per screen because that is what was asked for, and because
/// a second destructive action returning later should not need a second
/// budget bolted on beside it.
@MainActor
final class ActionQuota: ObservableObject {
    static let shared = ActionQuota()

    /// Free actions granted at the start of each calendar day.
    static let dailyFreeLimit = 20
    /// Actions granted per rewarded-ad view, on top of whatever is left.
    static let rewardedAdBonus = 20

    @Published private(set) var remaining: Int

    private static let remainingKey = "actionQuota.remaining"
    private static let lastResetDayKey = "actionQuota.lastResetDay"

    private init() {
        let defaults = UserDefaults.standard
        remaining = defaults.object(forKey: Self.remainingKey) != nil
            ? defaults.integer(forKey: Self.remainingKey)
            : Self.dailyFreeLimit
        resetIfNeeded()
    }

    /// Ask before putting up any destructive-action confirmation.
    func canConsume(_ count: Int) -> Bool {
        resetIfNeeded()
        return remaining >= count
    }

    /// Call only once the action has actually gone through -- a cancelled or
    /// failed delete must not cost anything.
    func consume(_ count: Int) {
        resetIfNeeded()
        remaining = max(0, remaining - count)
        persist()
    }

    /// Called from the rewarded-ad reward callback, never from the mere fact
    /// that the ad was shown or dismissed.
    func grantRewardedBonus() {
        remaining += Self.rewardedAdBonus
        persist()
    }

    /// Refills to the flat daily limit once per calendar day. Deliberately a
    /// flat reset rather than "top up to at least the limit" -- an
    /// ad-earned bonus is meant to be spent the day it is earned, not banked
    /// indefinitely.
    private func resetIfNeeded() {
        let defaults = UserDefaults.standard
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let lastReset = defaults.object(forKey: Self.lastResetDayKey) as? Date,
           calendar.isDate(lastReset, inSameDayAs: today) {
            return
        }
        remaining = Self.dailyFreeLimit
        defaults.set(today, forKey: Self.lastResetDayKey)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(remaining, forKey: Self.remainingKey)
    }
}
