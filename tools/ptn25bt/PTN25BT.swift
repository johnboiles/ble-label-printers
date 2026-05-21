import CoreBluetooth
import Foundation

let serviceUUID = CBUUID(string: "A76EB9E0-F3AC-4990-84CF-3A94D2426B2B")
let readUUID = CBUUID(string: "A76EB9E1-F3AC-4990-84CF-3A94D2426B2B")
let writeUUID = CBUUID(string: "A76EB9E2-F3AC-4990-84CF-3A94D2426B2B")
let writeNoResponseNotifyUUID = CBUUID(string: "A76EB9E3-F3AC-4990-84CF-3A94D2426B2B")
let notify2UUID = CBUUID(string: "A76EB9E4-F3AC-4990-84CF-3A94D2426B2B")

enum Command {
    case status
    case sendFile(String)
}

struct Options {
    var targetName = "PT-N25BT"
    var scanSeconds: TimeInterval = 20
    var postSendWaitSeconds: TimeInterval = 10
    var command: Command
}

func logLine(_ message: String) {
    print(message)
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func usage() -> Never {
    fputs("""
    Usage:
      ptn25bt [--name NAME] [--scan-seconds SECONDS] status
      ptn25bt [--name NAME] [--scan-seconds SECONDS] [--post-wait SECONDS] send-file PATH

    """, stderr)
    exit(2)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var targetName = "PT-N25BT"
    var scanSeconds: TimeInterval = 20
    var postSendWaitSeconds: TimeInterval = 10

    while let first = args.first, first.hasPrefix("--") {
        let option = args.removeFirst()
        switch option {
        case "--name":
            guard let value = args.first else { usage() }
            targetName = value
            args.removeFirst()
        case "--scan-seconds":
            guard let value = args.first, let seconds = Double(value) else { usage() }
            scanSeconds = seconds
            args.removeFirst()
        case "--post-wait":
            guard let value = args.first, let seconds = Double(value) else { usage() }
            postSendWaitSeconds = seconds
            args.removeFirst()
        case "--help", "-h":
            usage()
        default:
            usage()
        }
    }

    guard let commandName = args.first else { usage() }
    args.removeFirst()

    let command: Command
    switch commandName {
    case "status":
        guard args.isEmpty else { usage() }
        command = .status
    case "send-file":
        guard let path = args.first, args.count == 1 else { usage() }
        command = .sendFile(path)
    default:
        usage()
    }

    return Options(targetName: targetName, scanSeconds: scanSeconds, postSendWaitSeconds: postSendWaitSeconds, command: command)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func statusRequestBytes() -> Data {
    var data = Data(repeating: 0x00, count: 64)
    data.append(contentsOf: [0x1b, 0x40])
    data.append(contentsOf: [0x1b, 0x69, 0x53])
    return data
}

func describeStatus(_ data: Data) -> String {
    guard data.count >= 32 else { return "status too short: \(data.count) bytes" }
    let bytes = Array(data.prefix(32))
    guard bytes[0] == 0x80, bytes[1] == 0x20, bytes[2] == 0x42 else {
        return "unexpected status magic: \(hex(Data(bytes.prefix(4))))"
    }

    let errors = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
    let width = bytes[10]
    let mediaType = bytes[11]
    let statusType = bytes[18]
    let phase = (UInt32(bytes[19]) << 16) | (UInt32(bytes[20]) << 8) | UInt32(bytes[21])
    let bg = bytes[24]
    let fg = bytes[25]

    return "series=0x\(String(format: "%02x", bytes[3])) model=0x\(String(format: "%02x", bytes[4])) errors=0x\(String(format: "%04x", errors)) width=\(width)mm media=0x\(String(format: "%02x", mediaType)) statusType=0x\(String(format: "%02x", statusType)) phase=0x\(String(format: "%06x", phase)) tapeBg=0x\(String(format: "%02x", bg)) tapeFg=0x\(String(format: "%02x", fg))"
}

final class PTN25BTClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let options: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeResponseChar: CBCharacteristic?
    private var writeNoResponseNotifyChar: CBCharacteristic?
    private var notify2Char: CBCharacteristic?
    private var readChar: CBCharacteristic?
    private var notifyReady = Set<CBUUID>()
    private var rxData = Data()
    private var ackContinuation: CheckedContinuation<Bool, Never>?
    private var writeResponseContinuation: CheckedContinuation<Bool, Never>?
    private var didRunCommand = false

    init(options: Options) {
        self.options = options
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scan()
        case .poweredOff:
            fail("Bluetooth is powered off")
        case .unauthorized:
            fail("Bluetooth access is unauthorized")
        case .unsupported:
            fail("Bluetooth LE is unsupported")
        case .resetting, .unknown:
            break
        @unknown default:
            fail("Unknown Bluetooth state \(central.state.rawValue)")
        }
    }

    private func scan() {
        logLine("Scanning for \(options.targetName), service \(serviceUUID.uuidString)")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) {
            if self.peripheral == nil {
                self.central.stopScan()
                fail("Timed out waiting for \(self.options.targetName)")
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        guard name.localizedCaseInsensitiveContains(options.targetName) else { return }

        logLine("Connecting to \(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logLine("Connected")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Connect failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            fail("Disconnected: \(error.localizedDescription)")
        }
        logLine("Disconnected")
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("Discover services failed: \(error.localizedDescription)") }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail("Target service not found")
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("Discover characteristics failed: \(error.localizedDescription)") }

        for characteristic in service.characteristics ?? [] {
            logLine("Characteristic \(characteristic.uuid.uuidString) props=\(characteristic.properties.rawValue)")
            switch characteristic.uuid {
            case writeUUID:
                writeResponseChar = characteristic
            case writeNoResponseNotifyUUID:
                writeNoResponseNotifyChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case notify2UUID:
                notify2Char = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case readUUID:
                readChar = characteristic
            default:
                break
            }
        }

        guard writeNoResponseNotifyChar != nil || writeResponseChar != nil else {
            fail("No usable write characteristic")
        }
        maybeRunCommand()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Notify setup failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)") }
        if characteristic.isNotifying {
            notifyReady.insert(characteristic.uuid)
            logLine("Notify enabled on \(characteristic.uuid.uuidString)")
        }
        maybeRunCommand()
    }

    private func maybeRunCommand() {
        guard !didRunCommand, let peripheral else { return }
        if writeNoResponseNotifyChar != nil {
            guard notifyReady.contains(writeNoResponseNotifyUUID) else { return }
        }
        if notify2Char != nil {
            guard notifyReady.contains(notify2UUID) else { return }
        }
        didRunCommand = true

        Task {
            if writeNoResponseNotifyChar != nil, let pairChar = writeResponseChar {
                logLine("Writing BLE pairing probe")
                let ok = await writeWithResponse(Data([0x00]), to: pairChar)
                logLine("Pairing probe \(ok ? "accepted" : "failed")")
            }

            switch options.command {
            case .status:
                logLine("Sending status request")
                let ok = await sendFramed(statusRequestBytes())
                if !ok { fail("Status request write failed") }
                if let status = await waitForPrinterData(minBytes: 32, timeoutSeconds: 5) {
                    logLine("statusRaw=\(hex(status.prefixData(32)))")
                    logLine(describeStatus(status))
                } else {
                    fail("Timed out waiting for status data")
                }
            case .sendFile(let path):
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    logLine("Sending \(data.count) bytes from \(path)")
                    let ok = await sendFramed(data)
                    if !ok { fail("File write failed") }
                    logLine("File sent")
                    logLine("Waiting \(options.postSendWaitSeconds)s for printer status notifications")
                    try? await Task.sleep(nanoseconds: UInt64(options.postSendWaitSeconds * 1_000_000_000))
                } catch {
                    fail("Could not read \(path): \(error.localizedDescription)")
                }
            }

            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func writeWithResponse(_ data: Data, to characteristic: CBCharacteristic) async -> Bool {
        await withCheckedContinuation { continuation in
            writeResponseContinuation = continuation
            peripheral?.writeValue(data, for: characteristic, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if let pending = self.writeResponseContinuation {
                    self.writeResponseContinuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let pending = writeResponseContinuation {
            writeResponseContinuation = nil
            pending.resume(returning: error == nil)
        }
    }

    private func sendFramed(_ data: Data) async -> Bool {
        guard let peripheral else { return false }
        if let char = writeNoResponseNotifyChar {
            let maxWrite = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            let segmentPayloadMax = max(1, min(maxWrite * 8 - 4, 4092))
            logLine("Using write-without-response maxWrite=\(maxWrite) segmentPayloadMax=\(segmentPayloadMax)")

            var offset = 0
            while offset < data.count {
                let end = min(offset + segmentPayloadMax, data.count)
                let segment = data.subdata(in: offset..<end)
                let packetCount = UInt8((segment.count + 4 + maxWrite - 1) / maxWrite)
                var packet = Data([0x06, 0xf0, packetCount, 0x00])
                packet.append(segment)

                let ok = await sendFramedSegment(packet, to: char, chunkSize: maxWrite)
                if !ok { return false }
                offset = end
            }
            return true
        }

        if let char = writeResponseChar {
            var offset = 0
            let maxWrite = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
            while offset < data.count {
                let end = min(offset + maxWrite, data.count)
                if !(await writeWithResponse(data.subdata(in: offset..<end), to: char)) {
                    return false
                }
                offset = end
            }
            return true
        }

        return false
    }

    private func sendFramedSegment(_ packet: Data, to characteristic: CBCharacteristic, chunkSize: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            ackContinuation = continuation
            var offset = 0
            while offset < packet.count {
                let end = min(offset + chunkSize, packet.count)
                let chunk = packet.subdata(in: offset..<end)
                peripheral?.writeValue(chunk, for: characteristic, type: .withoutResponse)
                offset = end
                Thread.sleep(forTimeInterval: 0.005)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if let pending = self.ackContinuation {
                    self.ackContinuation = nil
                    pending.resume(returning: false)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logLine("Notify/read error on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }

        if characteristic.uuid == writeNoResponseNotifyUUID {
            logLine("ackRaw=\(hex(value))")
            if value.count == 3, value[0] == 0x06, value[1] == 0xf0 {
                let ok = value[2] == 0x01
                if let pending = ackContinuation {
                    ackContinuation = nil
                    pending.resume(returning: ok)
                }
            }
            return
        }

        if characteristic.uuid == notify2UUID || characteristic.uuid == readUUID {
            logLine("printerDataRaw=\(hex(value))")
            rxData.append(value)
        }
    }

    private func waitForPrinterData(minBytes: Int, timeoutSeconds: TimeInterval) async -> Data? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if rxData.count >= minBytes {
                return rxData
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }
}

private extension Data {
    func prefixData(_ maxLength: Int) -> Data {
        Data(prefix(maxLength))
    }
}

logLine("Starting ptn25bt")
var client: PTN25BTClient? = PTN25BTClient(options: parseOptions())
RunLoop.main.run()
