import AppKit

// Bootstrapping the app via pure AppKit (instead of SwiftUI's `App` + `Settings`
// scene) means we don't link against the SwiftUI / Combine / RealityKit
// runtimes. That shaves ~10 MB of resident memory and several threads off an
// otherwise trivial menu-bar app.
//
// `NSApplication.delegate` is a weak reference, so the delegate is held by
// `AppDelegate.shared` (a strong static) to keep it alive for the lifetime of
// the process.
@main
enum KoffeinumApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = AppDelegate.shared
        // LSUIElement in Info.plist already sets the activation policy to
        // `.accessory`, so no `setActivationPolicy` call is needed.
        app.run()
    }
}
