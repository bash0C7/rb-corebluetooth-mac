@preconcurrency import CoreBluetooth
import Foundation

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

final class VirtualPeripheral: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    let name: String
    let serviceUUID: CBUUID
    let notifyChar: CBMutableCharacteristic
    let rwChar: CBMutableCharacteristic
    let queue = DispatchQueue(label: "virtual_peripheral")
    var manager: CBPeripheralManager!
    var stored = Data("init".utf8)
    var seq: UInt32 = 0
    var pending: Data?
    var timer: DispatchSourceTimer?
    var stopping = false

    init(name: String, service: String, notify: String, rw: String) {
        self.name = name
        self.serviceUUID = CBUUID(string: service)
        self.notifyChar = CBMutableCharacteristic(type: CBUUID(string: notify), properties: [.notify], value: nil, permissions: [])
        self.rwChar = CBMutableCharacteristic(type: CBUUID(string: rw), properties: [.read, .write], value: nil, permissions: [.readable, .writeable])
        super.init()
    }

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func stop() {
        queue.async {
            if self.stopping { return }
            self.stopping = true
            self.timer?.cancel()
            if let m = self.manager {
                m.stopAdvertising()
                m.removeAllServices()
            }
            emit("stopped")
            exit(0)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [notifyChar, rwChar]
            peripheral.add(service)
        case .unknown, .resetting:
            break
        default:
            emit("error state \(peripheral.state.rawValue)")
            exit(3)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            emit("error add \(error.localizedDescription)")
            exit(4)
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: name,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            emit("error advertise \(error.localizedDescription)")
            exit(5)
        }
        emit("advertising \(serviceUUID.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        seq = 0
        pending = nil
        emit("subscribed")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        timer?.cancel()
        timer = nil
        pending = nil
        emit("unsubscribed \(seq)")
    }

    func tick() {
        if pending == nil {
            var be = seq.bigEndian
            pending = Data([0xA5, 0x5A]) + Data(bytes: &be, count: 4)
        }
        flush()
    }

    func flush() {
        guard let value = pending else { return }
        if manager.updateValue(value, for: notifyChar, onSubscribedCentrals: nil) {
            pending = nil
            seq += 1
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == rwChar.uuid else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= stored.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = stored.subdata(in: request.offset..<stored.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == rwChar.uuid }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        for r in requests {
            let v = r.value ?? Data()
            if r.offset == 0 {
                stored = v
            } else {
                stored = stored.prefix(r.offset) + v
            }
        }
        emit("write \(stored.map { String(format: "%02x", $0) }.joined())")
        peripheral.respond(to: first, withResult: .success)
    }
}

guard CBManager.authorization != .denied, CBManager.authorization != .restricted else {
    emit("error authorization \(CBManager.authorization.rawValue)")
    exit(2)
}

let suffix = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
let vp = VirtualPeripheral(
    name: "swiftgem-test-\(suffix)",
    service: UUID().uuidString,
    notify: UUID().uuidString,
    rw: UUID().uuidString
)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources = [SIGTERM, SIGINT].map { sig in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler { vp.stop() }
    s.resume()
    return s
}

Thread {
    while !FileHandle.standardInput.availableData.isEmpty {}
    vp.stop()
}.start()

vp.start()
dispatchMain()
