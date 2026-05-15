import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    private init() {}

    func enqueue(characteristic: CBCharacteristic, error: Error?) {
        // Real impl arrives in Task 18.
    }
}
