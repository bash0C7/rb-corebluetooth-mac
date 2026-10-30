@preconcurrency import CoreBluetooth
import Foundation
import os

/// The notification queues of every subscription, keyed by subscription id.
final class CBMSubscriptionRegistry: @unchecked Sendable {
    static let shared = CBMSubscriptionRegistry()
    init() {}

    /// One subscription. `queue` and `closed` are read and written only under the registry lock.
    ///
    /// `semaphore` is signaled once per queued value and once on closing.
    final class Entry: @unchecked Sendable {
        let centralId: Int64
        let peripheral: UUID
        let characteristicUUID: CBUUID
        var queue: [Data] = []
        var closed: Bool = false
        let semaphore = DispatchSemaphore(value: 0)
        init(centralId: Int64, peripheral: UUID, characteristicUUID: CBUUID) {
            self.centralId = centralId
            self.peripheral = peripheral
            self.characteristicUUID = characteristicUUID
        }
    }

    private let lock = OSAllocatedUnfairLock<[Int64: Entry]>(initialState: [:])
    private static let idCounter = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func register(centralId: Int64, peripheral: UUID, characteristicUUID: CBUUID) -> Int64 {
        let assigned = Self.idCounter.withLock { state in
            state += 1
            return state
        }
        let entry = Entry(centralId: centralId, peripheral: peripheral, characteristicUUID: characteristicUUID)
        lock.withLock { $0[assigned] = entry }
        return assigned
    }

    /// Appends `value` to every open subscription on the central for the peripheral's characteristic.
    func enqueue(_ value: Data, centralId: Int64, peripheral: UUID, characteristicUUID: CBUUID) {
        lock.withLock { dict in
            for entry in dict.values where entry.centralId == centralId && entry.peripheral == peripheral
                && entry.characteristicUUID == characteristicUUID && !entry.closed {
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

    /// Closes the subscription and forgets it, as if it was never registered.
    func remove(subscriptionId: Int64) {
        lock.withLock { dict in
            if let e = dict.removeValue(forKey: subscriptionId) { Self.markClosed(e) }
        }
    }

    private static func markClosed(_ e: Entry) {
        if e.closed { return }
        e.closed = true
        e.semaphore.signal()
    }

    func purgeAll(centralId: Int64) {
        purge { $0.centralId == centralId }
    }

    /// Closes and removes the subscriptions on the central for the peripheral's characteristic, leaving the others open.
    func purgeMatching(centralId: Int64, peripheral: UUID, characteristicUUID: CBUUID) {
        purge { $0.centralId == centralId && $0.peripheral == peripheral && $0.characteristicUUID == characteristicUUID }
    }

    /// Closes and removes every subscription on the central for the disconnected `peripheral`.
    func disconnected(centralId: Int64, peripheral: UUID) {
        purge { $0.centralId == centralId && $0.peripheral == peripheral }
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
