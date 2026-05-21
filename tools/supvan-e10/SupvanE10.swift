import CoreBluetooth
import Foundation

let supvanServiceUUID = CBUUID(string: "0000E0FF-3C17-D293-8E48-14FE2E4DA212")
let advertisedServiceUUID = CBUUID(string: "FEE7")
let notifyUUID = CBUUID(string: "FFE1")
let writeUUID = CBUUID(string: "FFE9")
let extraNotifyUUID = CBUUID(string: "FFEA")

enum Command {
    case status
    case sendFile(String)
    case sendHex(String)
}

struct Options {
    var targetName = "T0011"
    var scanSeconds: TimeInterval = 20
    var postSendWaitSeconds: TimeInterval = 8
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
      supvan-e10 [--name NAME] [--scan-seconds SECONDS] status
      supvan-e10 [--name NAME] [--scan-seconds SECONDS] [--post-wait SECONDS] send-file PATH
      supvan-e10 [--name NAME] [--scan-seconds SECONDS] send-hex HEX

    """, stderr)
    exit(2)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var targetName = "T0011"
    var scanSeconds: TimeInterval = 20
    var postSendWaitSeconds: TimeInterval = 8

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
    case "send-hex":
        guard let hex = args.first, args.count == 1 else { usage() }
        command = .sendHex(hex)
    default:
        usage()
    }

    return Options(targetName: targetName, scanSeconds: scanSeconds, postSendWaitSeconds: postSendWaitSeconds, command: command)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func parseHex(_ string: String) -> Data? {
    let filtered = string.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
    guard filtered.count % 2 == 0 else { return nil }
    var data = Data()
    var index = filtered.startIndex
    while index < filtered.endIndex {
        let next = filtered.index(index, offsetBy: 2)
        guard let byte = UInt8(filtered[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

func checksum(_ bytes: [UInt8], from start: Int, to endExclusive: Int) -> UInt16 {
    var total: UInt16 = 0
    for index in start..<endExclusive {
        total = total &+ UInt16(bytes[index])
    }
    return total
}

func commandFrame(_ command: UInt8, param: UInt16) -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = 0x7e
    bytes[1] = 0x5a
    bytes[2] = 0x0c
    bytes[4] = 0x5a
    bytes[5] = 0x01
    bytes[6] = 0xaa
    bytes[7] = command
    bytes[10] = 0x00
    bytes[11] = 0x01
    bytes[12] = UInt8(param & 0xff)
    bytes[13] = UInt8((param >> 8) & 0xff)
    let sum = checksum(bytes, from: 10, to: bytes.count)
    bytes[8] = UInt8(sum & 0xff)
    bytes[9] = UInt8((sum >> 8) & 0xff)
    return Data(bytes)
}

func startTransferFrame(command: UInt8, blockSize: UInt16, blockCount: UInt16) -> Data {
    var bytes = Array(commandFrame(command, param: blockSize))
    bytes[14] = UInt8(blockCount & 0xff)
    bytes[15] = UInt8((blockCount >> 8) & 0xff)
    let sum = checksum(bytes, from: 10, to: bytes.count)
    bytes[8] = UInt8(sum & 0xff)
    bytes[9] = UInt8((sum >> 8) & 0xff)
    return Data(bytes)
}

func bulkPayloadFrame(payload: Data, index: Int, count: Int) -> Data {
    var inner = [UInt8](repeating: 0, count: 506)
    inner[0] = 0xaa
    inner[1] = 0xbb
    inner[4] = UInt8(index & 0xff)
    inner[5] = UInt8(count & 0xff)
    let copyCount = min(payload.count, 500)
    inner.replaceSubrange(6..<(6 + copyCount), with: payload.prefix(copyCount))
    let innerSum = checksum(inner, from: 4, to: inner.count)
    inner[2] = UInt8(innerSum & 0xff)
    inner[3] = UInt8((innerSum >> 8) & 0xff)

    var outer = [UInt8](repeating: 0, count: 512)
    outer[0] = 0x7e
    outer[1] = 0x5a
    outer[2] = 0xfc
    outer[3] = 0x01
    outer[4] = 0x5a
    outer[5] = 0x02
    outer.replaceSubrange(6..<512, with: inner)
    return Data(outer)
}

struct SupvanJob {
    let chunks: [Data]

    static func load(path: String) throws -> SupvanJob {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let magic = Data("SUPVAN_E10_JOB\n".utf8)
        guard data.starts(with: magic) else {
            throw NSError(domain: "SupvanJob", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing SUPVAN_E10_JOB magic"])
        }
        var offset = magic.count

        func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw NSError(domain: "SupvanJob", code: 2, userInfo: [NSLocalizedDescriptionKey: "truncated job file"])
            }
            let value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            offset += 4
            return value
        }

        let count = Int(try readUInt32())
        var chunks: [Data] = []
        chunks.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(try readUInt32())
            guard offset + length <= data.count else {
                throw NSError(domain: "SupvanJob", code: 3, userInfo: [NSLocalizedDescriptionKey: "truncated compressed chunk"])
            }
            chunks.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return SupvanJob(chunks: chunks)
    }
}

final class SupvanE10Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let options: Options
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyReady = Set<CBUUID>()
    private var didRunCommand = false
    private var responseContinuation: CheckedContinuation<Data?, Never>?
    private var writeContinuation: CheckedContinuation<Bool, Never>?
    private var expectedResponseCommand: UInt8?
    private var pendingResponse: Data?

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
        logLine("Scanning for \(options.targetName)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matchesName = name.localizedCaseInsensitiveContains(options.targetName)
        let matchesService = services.contains(advertisedServiceUUID) && options.targetName.isEmpty
        guard self.peripheral == nil, matchesName || matchesService else { return }

        logLine("Connecting to \(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logLine("Connected")
        peripheral.discoverServices(nil)
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
        for service in peripheral.services ?? [] {
            logLine("Service \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("Discover characteristics failed for \(service.uuid.uuidString): \(error.localizedDescription)") }
        for characteristic in service.characteristics ?? [] {
            logLine("  Char \(characteristic.uuid.uuidString) props=\(characteristic.properties.rawValue)")
            if characteristic.uuid == writeUUID {
                writeChar = characteristic
            }
            if characteristic.uuid == notifyUUID || characteristic.uuid == extraNotifyUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
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
        guard !didRunCommand, writeChar != nil, notifyReady.contains(notifyUUID) else { return }
        didRunCommand = true
        Task {
            switch options.command {
            case .status:
                _ = await sendCommand(0x11, param: 0, label: "status")
            case .sendHex(let string):
                guard let data = parseHex(string) else { fail("Invalid hex string") }
                let ok = await writeWithResponse(data)
                logLine("send-hex wrote=\(ok) bytes=\(data.count)")
            case .sendFile(let path):
                do {
                    let job = try SupvanJob.load(path: path)
                    try await sendJob(job)
                } catch {
                    fail("send-file failed: \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + options.postSendWaitSeconds) {
                if let peripheral = self.peripheral {
                    self.central.cancelPeripheralConnection(peripheral)
                } else {
                    exit(0)
                }
            }
        }
    }

    private func sendJob(_ job: SupvanJob) async throws {
        logLine("Loaded job chunks=\(job.chunks.count)")
        _ = await sendCommand(0x11, param: 0, label: "status-before")
        _ = await sendCommand(0xc9, param: 110, label: "density")
        guard await sendCommand(0x13, param: 0, label: "start-print") != nil else {
            throw NSError(domain: "SupvanE10", code: 10, userInfo: [NSLocalizedDescriptionKey: "start-print did not ACK"])
        }
        try? await Task.sleep(nanoseconds: 300_000_000)

        for (chunkIndex, chunk) in job.chunks.enumerated() {
            let blockCount = UInt16((chunk.count + 499) / 500)
            let startFrame = startTransferFrame(command: 0x5c, blockSize: 512, blockCount: blockCount)
            guard await sendCommandFrame(0x5c, frame: startFrame, label: "start-transfer[\(chunkIndex)]") != nil else {
                throw NSError(domain: "SupvanE10", code: 11, userInfo: [NSLocalizedDescriptionKey: "start-transfer did not ACK"])
            }

            for blockIndex in 0..<Int(blockCount) {
                let start = blockIndex * 500
                let end = min(start + 500, chunk.count)
                let payload = chunk.subdata(in: start..<end)
                let frame = bulkPayloadFrame(payload: payload, index: blockIndex, count: Int(blockCount))
                for part in 0..<4 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let partStart = part * 128
                    let partEnd = partStart + 128
                    let writeOK = await writeWithResponse(frame.subdata(in: partStart..<partEnd))
                    if !writeOK {
                        throw NSError(domain: "SupvanE10", code: 12, userInfo: [NSLocalizedDescriptionKey: "bulk write failed"])
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await sendCommand(0x10, param: 0, label: "buffer-full[\(chunkIndex)]")
            _ = await sendCommand(0x11, param: 0, label: "status-after-buffer[\(chunkIndex)]")
        }

        _ = await sendCommand(0x11, param: 0, label: "status-after")
    }

    private func sendCommand(_ command: UInt8, param: UInt16, label: String) async -> Data? {
        await sendCommandFrame(command, frame: commandFrame(command, param: param), label: label)
    }

    private func sendCommandFrame(_ command: UInt8, frame: Data, label: String) async -> Data? {
        logLine("TX \(label) cmd=0x\(String(format: "%02x", command)) \(hex(frame))")
        expectedResponseCommand = command
        pendingResponse = nil
        let writeOK = await writeWithResponse(frame)
        guard writeOK else {
            logLine("  write failed")
            expectedResponseCommand = nil
            return nil
        }
        if let pendingResponse {
            self.pendingResponse = nil
            self.expectedResponseCommand = nil
            logLine("RX \(label) \(hex(pendingResponse))")
            return pendingResponse
        }
        let response = await withCheckedContinuation { continuation in
            responseContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.responseContinuation != nil {
                    self.responseContinuation?.resume(returning: nil)
                    self.responseContinuation = nil
                    self.expectedResponseCommand = nil
                }
            }
        }
        if let response {
            logLine("RX \(label) \(hex(response))")
        } else {
            logLine("RX \(label) timeout")
        }
        return response
    }

    private func writeWithResponse(_ data: Data) async -> Bool {
        guard let peripheral, let writeChar else { return false }
        return await withCheckedContinuation { continuation in
            writeContinuation = continuation
            peripheral.writeValue(data, for: writeChar, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.writeContinuation != nil {
                    self.writeContinuation?.resume(returning: false)
                    self.writeContinuation = nil
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logLine("Write failed \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            writeContinuation?.resume(returning: false)
        } else {
            writeContinuation?.resume(returning: true)
        }
        writeContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logLine("Notify \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        logLine("Notify \(characteristic.uuid.uuidString)=\(hex(data))")
        guard data.count > 7, let expectedResponseCommand, data[7] == expectedResponseCommand else { return }
        if let responseContinuation {
            responseContinuation.resume(returning: data)
            self.responseContinuation = nil
            self.expectedResponseCommand = nil
        } else {
            pendingResponse = data
        }
    }
}

logLine("Starting supvan-e10")
var client: SupvanE10Client? = SupvanE10Client(options: parseOptions())
RunLoop.main.run()
