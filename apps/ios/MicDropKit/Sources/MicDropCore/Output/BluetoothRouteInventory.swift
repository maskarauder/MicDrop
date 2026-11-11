import Foundation

/// Returning-Bluetooth detector (port of `BluetoothMediaInventory.kt`).
///
/// "Detect returning media ports only. This never selects a particular headset or proves the actual route." On iOS the
/// input is the current route only, so `available` means "a Bluetooth media output (A2DP or LE; HFP has a nil kind and
/// is excluded) is in the current route". `bluetoothAdded` = route-change reason `.newDeviceAvailable` with a Bluetooth
/// output in the new route. Not internally synchronized (session audio lock).
public final class BluetoothRouteInventory: @unchecked Sendable {
    private var ports: Set<RouteOutput> = []
    public private(set) var available = false
    public private(set) var generation: Int64 = 0

    public init() {}

    /// `next` = Bluetooth-kind outputs; generation advances if `next` has an output not seen in the
    /// previous set, or if `bluetoothAdded` and `next` is non-empty. Removal alone never advances.
    public func update<C: Collection>(_ outputs: C, bluetoothAdded: Bool = false) where C.Element == RouteOutput {
        let next = Set(outputs.filter { $0.kind?.isBluetooth == true })
        if next.contains(where: { !ports.contains($0) }) || (bluetoothAdded && !next.isEmpty) {
            generation += 1
        }
        ports = next
        available = !next.isEmpty
    }
}
