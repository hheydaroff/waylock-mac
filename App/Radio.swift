import CoreBluetooth
import Foundation

/// The CoreBluetooth adapter: the only module that knows the radio exists.
///
/// It reports sightings and state changes and nothing else. The stall watchdog
/// lives here because it is a property of the radio — CoreBluetooth occasionally
/// never delivers its first state callback at all, and then the app looks healthy
/// while scanning nothing. That is the worst failure mode this app can have,
/// because it cannot be told apart from "the key is not here".
///
/// CoreBluetooth runs on its own queue. When macOS is waiting for a Bluetooth
/// permission decision the manager's initialiser can block the thread it is
/// called on, and that thread must not be the one drawing the menu bar — a
/// blocked main queue is indistinguishable from a hung app, and it also stops the
/// watchdog that would have explained it. Delegate work therefore stays on
/// `queue`, and everything the app can see (`state`, the callbacks) is delivered
/// on the main thread, so the rest of the app stays single-threaded.
final class Radio: NSObject, CBCentralManagerDelegate {
    /// Called for every advertisement worth reporting, on the main thread.
    var onSighting: ((Sighting) -> Void)?
    var onState: ((RadioState) -> Void)?
    var log: (String) -> Void = { _ in }
    /// Retrying a stalled radio is pointless while the app is switched off.
    var shouldRecover: () -> Bool = { true }

    /// Mirrored on the main thread for the menu; the radio queue is the authority.
    private(set) var state: RadioState = .unknown

    private let queue = DispatchQueue(label: "io.github.hheydaroff.waylock.radio")
    private var central: CBCentralManager?          // radio queue only
    private var scanning = false                    // radio queue only
    private var started = false                     // main thread only
    private var retries = 0                         // main thread only

    private static let stallCheck: TimeInterval = 15
    /// ~10 minutes of retries: when the cause is a pending permission prompt the
    /// user may be away, and one unlock should be enough to revive the app.
    private static let maxRetries = 40

    /// Called after the callbacks are wired. Returns immediately: the manager is
    /// created on the radio queue, because it can block on a permission decision.
    func start() {
        guard !started else { return }
        started = true
        queue.async { [self] in
            note("bluetooth: opening")
            open()
        }
        let watchdog = Timer.scheduledTimer(withTimeInterval: Self.stallCheck, repeats: true) {
            [weak self] _ in self?.recoverIfStalled()
        }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    func startScanning() {
        queue.async { [self] in beginScanning() }
    }

    func restartScanning() {
        queue.async { [self] in
            if scanning { central?.stopScan(); scanning = false }
            beginScanning()
        }
    }

    // ── radio queue ──────────────────────────────────────────────────────────

    private func open() {
        central = CBCentralManager(delegate: self, queue: queue)
        beginScanning()
    }

    private func beginScanning() {
        guard let central, central.state == .poweredOn, !scanning else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanning = true
        note("scanning")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // A central we have already replaced can still deliver one last callback.
        guard central === self.central else { return }
        let next = Self.map(central.state)
        if next == .on {
            retries = 0
            beginScanning()
        } else {
            scanning = false
        }
        DispatchQueue.main.async { [self] in
            if next != state { log("bluetooth state -> \(central.state.rawValue)") }
            state = next
            onState?(next)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData data: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi != 127, rssi != 0 else { return }   // 127 = "not available"
        let name = peripheral.name ?? (data[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let sighting = Sighting(name: name, address: peripheral.identifier, rssi: rssi)
        DispatchQueue.main.async { [self] in onSighting?(sighting) }
    }

    // ── main thread ──────────────────────────────────────────────────────────

    private func recoverIfStalled() {
        guard started, state != .on, shouldRecover(), retries < Self.maxRetries else { return }
        retries += 1
        if retries <= 3 || retries % 10 == 0 {
            let hint = state == .unknown
                ? "  [if a permission prompt is pending: every rebuild changes the ad-hoc"
                  + " signature, so macOS asks again — approve it, or sign with a stable identity]"
                : ""
            log("bluetooth stalled at \(state) — recreating central"
                + " (attempt \(retries))" + hint)
        }
        queue.async { [self] in open() }
    }

    /// Log lines can come from either thread; the sink (a file, or stdout) cannot.
    private func note(_ message: String) {
        if Thread.isMainThread {
            log(message)
        } else {
            DispatchQueue.main.async { [self] in log(message) }
        }
    }

    private static func map(_ state: CBManagerState) -> RadioState {
        switch state {
        case .poweredOn: return .on
        case .unknown, .resetting: return .unknown
        default: return .off
        }
    }
}