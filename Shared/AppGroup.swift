import Foundation

enum AppGroup {
    // App Groups entitlement was removed: with a free Apple ID, third-party
    // resigning tools (Sideloadly/AltStore) can fail to provision it correctly
    // on the extension target, which causes a CODESIGNING/"Invalid Page" crash
    // at launch. Each process now uses its own UserDefaults.standard instead,
    // so history is no longer shared between the app and the extension.
    static var defaults: UserDefaults {
        .standard
    }
}
