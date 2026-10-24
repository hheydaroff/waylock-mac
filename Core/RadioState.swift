import Foundation

/// The Bluetooth radio as the rest of the app sees it.
///
/// `.unknown` is not "off": in practice it means CoreBluetooth never delivered a
/// state callback at all, which is what a pending permission prompt looks like —
/// and it is the one state where the app can look healthy while scanning nothing.
enum RadioState: Equatable {
    case unknown
    case off
    case on
}