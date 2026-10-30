@preconcurrency import CoreBluetooth
import Foundation
import os

/// The notification queues of every subscription, keyed by subscription id.
final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    private init() {}

    /// One subscription. `queue` and `closed` are read and written only under the registry lock.
    ///
    /// `semaphore` is signaled once per queued value and once on closing.
    final class Entry: @unchecked Sendable {
        weak var central: CBMCentral?
        let characteristicUUID: CBUUID
        var queue: [Data] = []
        var closed: Bool = false
        let semaphore = DispatchSemaphore(value: 0)
        init(central: CBMCentral, characteristicUUID: CBUUID) {
            self.central = central
            self.characteristicUUID = characteristicUUID
        }
    }

    private let lock = OSAllocatedUnfairLock<[Int64: Entry]>(initialState: [:])
    private static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func register(central: CBMCentral, characteristicUUID: CBUUID) -> Int64 {
        let assigned = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        let entry = Entry(central: central, characteristicUUID: characteristicUUID)
        lock.withLock { $0[assigned] = entry }
        return assigned
    }

    /// Appends the characteristic's value to every open subscription for its UUID.
    func enqueue(characteristic: CBCharacteristic) {
        let value = characteristic.value ?? Data()
        lock.withLock { dict in
            for entry in dict.values where entry.characteristicUUID == characteristic.uuid && !entry.closed {
                entry.queue.append(value)
                entry.semaphore.signal()
            }
        }
    }

    /// Takes the oldest value, waiting up to `timeoutMs` milliseconds for one.
    ///
    /// - Returns: The value, or `nil` on timeout; `closed` is true once the subscription is closed and drained or unknown.
    func dequeue(subscriptionId: Int64, timeoutMs: Int32, cancel: CBMCancel) -> (data: Data?, closed: Bool) {
        guard let e = lock.withLock({ $0[subscriptionId] }) else { return (nil, true) }
        if lock.withLock({ _ in e.closed && e.queue.isEmpty }) { return (nil, true) }
        if cancel.wait(e.semaphore, until: deadline(timeoutMs)) == .timedOut { return (nil, false) }
        return lock.withLock { _ in (e.queue.isEmpty ? nil : e.queue.removeFirst(), e.closed) }
    }

    func close(subscriptionId: Int64) {
        lock.withLock { dict in
            if let e = dict[subscriptionId] { Self.markClosed(e) }
        }
    }

    private static func markClosed(_ e: Entry) {
        if e.closed { return }
        e.closed = true
        e.semaphore.signal()
    }

    func purgeAll(under central: CBMCentral) {
        purge { $0.central === central }
    }

    /// Closes and removes the subscriptions on `central` for `characteristicUUID`, leaving the others open.
    func purgeMatching(under central: CBMCentral, characteristicUUID: CBUUID) {
        purge { $0.central === central && $0.characteristicUUID == characteristicUUID }
    }

    private func purge(where matches: @Sendable (Entry) -> Bool) {
        lock.withLock { dict in
            for (id, entry) in dict where matches(entry) {
                Self.markClosed(entry)
                dict.removeValue(forKey: id)
            }
        }
    }
}
