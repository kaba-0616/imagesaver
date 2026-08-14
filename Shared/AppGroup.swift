import Foundation

enum AppGroup {
    static let identifier = "group.jp.kaba.imagesaver"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
