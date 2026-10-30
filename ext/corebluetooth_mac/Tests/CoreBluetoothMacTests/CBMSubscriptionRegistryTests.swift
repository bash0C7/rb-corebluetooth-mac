import CoreBluetooth
import Foundation
import Testing
@testable import CoreBluetoothMac

@Suite struct CBMSubscriptionRegistryTests {
    let registry = CBMSubscriptionRegistry()
    let char = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    let peripheralA = UUID()
    let peripheralB = UUID()

    func next(_ id: Int64) -> (data: Data?, closed: Bool) {
        registry.dequeue(subscriptionId: id, timeoutMs: 0, cancel: CBMCancel())
    }

    @Test func valueGoesOnlyToThePeripheralThatSentIt() {
        let a = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        let b = registry.register(centralId: 1, peripheral: peripheralB, characteristicUUID: char)
        registry.enqueue(Data([1]), centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        #expect(next(a).data == Data([1]))
        #expect(next(b).data == nil)
    }

    @Test func valueGoesOnlyToTheCentralThatReceivedIt() {
        let one = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        let two = registry.register(centralId: 2, peripheral: peripheralA, characteristicUUID: char)
        registry.enqueue(Data([2]), centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        #expect(next(one).data == Data([2]))
        #expect(next(two).data == nil)
    }

    @Test func valueArrivingRightAfterRegistrationIsKept() {
        let id = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        registry.enqueue(Data([0]), centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        registry.enqueue(Data([1]), centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        #expect(next(id).data == Data([0]))
        #expect(next(id).data == Data([1]))
    }

    @Test func disconnectionClosesThatPeripheralsSubscriptions() {
        let a = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        let b = registry.register(centralId: 1, peripheral: peripheralB, characteristicUUID: char)
        let other = registry.register(centralId: 2, peripheral: peripheralA, characteristicUUID: char)
        registry.disconnected(centralId: 1, peripheral: peripheralA)
        #expect(next(a).closed)
        #expect(!next(b).closed)
        #expect(!next(other).closed)
    }

    @Test func unsubscribeClosesOnlyTheMatchingSubscriptions() {
        let otherChar = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        let target = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        let sameCharOtherPeripheral = registry.register(centralId: 1, peripheral: peripheralB, characteristicUUID: char)
        let otherCharSamePeripheral = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: otherChar)
        let otherCentral = registry.register(centralId: 2, peripheral: peripheralA, characteristicUUID: char)
        registry.purgeMatching(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        #expect(next(target).closed)
        #expect(!next(sameCharOtherPeripheral).closed)
        #expect(!next(otherCharSamePeripheral).closed)
        #expect(!next(otherCentral).closed)
    }

    @Test func removeClosesAndForgetsTheSubscription() {
        let id = registry.register(centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        registry.enqueue(Data([9]), centralId: 1, peripheral: peripheralA, characteristicUUID: char)
        registry.remove(subscriptionId: id)
        #expect(next(id) == (nil, true))
    }
}
