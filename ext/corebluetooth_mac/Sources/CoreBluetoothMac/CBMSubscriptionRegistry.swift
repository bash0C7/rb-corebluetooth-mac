import Foundation
@preconcurrency import CoreBluetooth
import os

final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    private init() {}

    // `@unchecked Sendable` is required because `OSAllocatedUnfairLock<[Int64: Entry]>`
    // captures the dictionary in `@Sendable` closures; the outer class's `@unchecked`
    // does not propagate to nested classes under Swift 6 strict concurrency. All
    // mutable state (`queue`, `closed`) is serialized via the outer `lock`.
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
    // Locking the counter inside the lock state avoids Swift 6 static-mutable errors.
    private static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func register(central: CBMCentral, characteristicUUID: CBUUID) -> Int64 {
        let assigned: Int64 = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        let entry = Entry(central: central, characteristicUUID: characteristicUUID)
        lock.withLock { $0[assigned] = entry }
        return assigned
    }

    func enqueue(characteristic: CBCharacteristic, error: Error?) {
        // Fan out to every entry watching this UUID.
        // (We don't have a back-pointer from characteristic→subscription_id;
        // looping is cheap given queue sizes.)
        let value = characteristic.value ?? Data()
        lock.withLock { dict in
            for (_, entry) in dict {
                if entry.characteristicUUID == characteristic.uuid && !entry.closed {
                    entry.queue.append(value)
                    entry.semaphore.signal()
                }
            }
        }
    }

    func dequeue(subscriptionId: Int64, timeoutMs: Int32) -> (data: Data?, closed: Bool) {
        let entry: Entry? = lock.withLock { $0[subscriptionId] }
        guard let e = entry else { return (nil, true) }
        if e.closed && e.queue.isEmpty { return (nil, true) }
        if let first = lock.withLock({ _ -> Data? in e.queue.isEmpty ? nil : e.queue.removeFirst() }) {
            return (first, false)
        }
        let r = e.semaphore.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
        if r == .timedOut { return (nil, false) }
        let popped: Data? = lock.withLock { _ in e.queue.isEmpty ? nil : e.queue.removeFirst() }
        return (popped, e.closed)
    }

    func close(subscriptionId: Int64) {
        let entry: Entry? = lock.withLock { $0[subscriptionId] }
        guard let e = entry else { return }
        e.closed = true
        e.semaphore.signal()
    }

    func purge(subscriptionId: Int64) {
        // Discard the removed value explicitly; Swift 6 warns on unused withLock return.
        lock.withLock { _ = $0.removeValue(forKey: subscriptionId) }
    }

    func purgeAll(under central: CBMCentral) {
        // Snapshot ids first; mutating a Swift Dictionary while iterating it
        // via `for (k, v) in dict` is undefined behavior.
        lock.withLock { dict in
            let ids = dict.compactMap { (id, entry) in entry.central === central ? id : nil }
            for id in ids {
                if let entry = dict[id] {
                    entry.closed = true
                    entry.semaphore.signal()
                }
                dict.removeValue(forKey: id)
            }
        }
    }

    // Close + drop only the subscriptions matching both `central` and the
    // given characteristic UUID. Used by `Characteristic#unsubscribe` so that
    // other subscriptions on the same central (e.g. a second char being
    // notified concurrently) survive. Snapshot-then-mutate for the same
    // reason as `purgeAll`.
    func purgeMatching(under central: CBMCentral, characteristicUUID: CBUUID) {
        lock.withLock { dict in
            let ids = dict.compactMap { (id, entry) in
                (entry.central === central && entry.characteristicUUID == characteristicUUID) ? id : nil
            }
            for id in ids {
                if let entry = dict[id] {
                    entry.closed = true
                    entry.semaphore.signal()
                }
                dict.removeValue(forKey: id)
            }
        }
    }
}
