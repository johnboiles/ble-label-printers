import Foundation
import CoreBluetooth

enum Command {
    case status
    case sendFile(String)
    case validateFile(String)
}

struct Options {
    var targetName: String?
    var targetID: UUID?
    var scanSeconds: TimeInterval = 30
    var command: Command = .status

    var targetDescription: String {
        if let targetID { return "UUID \(targetID.uuidString)" }
        if let targetName { return "exact name \(targetName)" }
        return "B21S or B21S-* name"
    }

    func matches(id: UUID, name: String?) -> Bool {
        if let targetID { return id == targetID }
        guard let name else { return false }
        if let targetName { return name == targetName }
        return name == "B21S" || name.hasPrefix("B21S-")
    }
}

func usage() {
    print("""
    Usage:
      niimbot-b21s [options] status
      niimbot-b21s [options] send-file PATH
      niimbot-b21s [options] validate-file PATH

    Options:
      --name NAME             Exact advertised name (default: B21S or B21S-*)
      --uuid UUID             Exact peripheral UUID; takes precedence over --name
      --scan-seconds SECONDS  Scan timeout, greater than 0 and at most 3600 (default: 30)
      --help, -h              Show this help without accessing Bluetooth

    Files contain a JSON array of packet steps. validate-file is offline.
    --job PATH and --validate-job PATH alias send-file and validate-file.
    Exit codes: 0 success, 1 Bluetooth/job failure, 2 invalid arguments/job.
    """)
}

func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let first = args.first {
        if first == "--help" || first == "-h" { usage(); exit(0) }
        guard ["--name", "--uuid", "--scan-seconds"].contains(first) else { break }
        args.removeFirst()
        guard !args.isEmpty else { throw JobError.invalid("Missing value for \(first)") }
        let value = args.removeFirst()
        switch first {
        case "--name":
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw JobError.invalid("--name must not be empty")
            }
            options.targetName = value
        case "--uuid":
            guard let uuid = UUID(uuidString: value) else { throw JobError.invalid("Invalid --uuid") }
            options.targetID = uuid
        case "--scan-seconds":
            guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 3600 else {
                throw JobError.invalid("--scan-seconds must be greater than 0 and at most 3600")
            }
            options.scanSeconds = seconds
        default: break
        }
    }
    guard !args.isEmpty else { throw JobError.invalid("Missing command; use --help") }
    let command = args.removeFirst()
    switch command {
    case "status":
        guard args.isEmpty else { throw JobError.invalid("status takes no arguments") }
        options.command = .status
    case "send-file", "--job", "validate-file", "--validate-job":
        guard args.count == 1, !args[0].isEmpty else { throw JobError.invalid("\(command) requires one file path") }
        options.command = ["send-file", "--job"].contains(command) ? .sendFile(args[0]) : .validateFile(args[0])
    default: throw JobError.invalid("Unknown command \(command); use --help")
    }
    return options
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ string: String) throws -> Data {
    let clean = string.filter { !$0.isWhitespace }
    guard clean.count % 2 == 0 else { throw JobError.invalid("Odd hex length") }
    guard clean.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
        throw JobError.invalid("Hex data must contain only hexadecimal digits and whitespace")
    }
    var result = Data()
    var index = clean.startIndex
    while index < clean.endIndex {
        let end = clean.index(index, offsetBy: 2)
        guard let byte = UInt8(clean[index..<end], radix: 16) else {
            throw JobError.invalid("Invalid hex: \(clean[index..<end])")
        }
        result.append(byte)
        index = end
    }
    return result
}

enum JobError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

struct Step: Decodable {
    let name: String
    let hex: String
    let expect: Int?
    let expectData: String?
    let expectPrefix: String?
    let timeout: Double?
    let optional: Bool?
    let delay: Double?
    let repeatUntilData: String?
    let repeatUntilPrefix: String?
    let maxAttempts: Int?
}

struct PreparedStep {
    let specification: Step
    let packet: Data
    let expectedData: Data?
    let expectedPrefix: Data?
    let repeatData: Data?
    let repeatPrefix: Data?
    var wait: Double { specification.timeout ?? 3 }
    var delay: Double { specification.delay ?? 0.05 }
    var maxAttempts: Int { specification.maxAttempts ?? 30 }
    var isPolling: Bool { repeatData != nil || repeatPrefix != nil }

    init(_ step: Step) throws {
        specification = step
        packet = try unhex(step.hex)
        expectedData = try step.expectData.map(unhex)
        expectedPrefix = try step.expectPrefix.map(unhex)
        repeatData = try step.repeatUntilData.map(unhex)
        repeatPrefix = try step.repeatUntilPrefix.map(unhex)
        var bytes = [UInt8](packet)
        // B21S Connect (C1) includes an out-of-frame 03 wake-up byte.
        if bytes.count >= 4 && bytes[0] == 0x03 && bytes[1] == 0x55 && bytes[2] == 0x55 && bytes[3] == 0xc1 {
            bytes.removeFirst()
        }
        guard bytes.count >= 7, bytes[0] == 0x55, bytes[1] == 0x55,
              bytes.count == Int(bytes[3]) + 7,
              bytes[bytes.count - 2] == 0xaa, bytes[bytes.count - 1] == 0xaa,
              bytes[2..<(bytes.count - 3)].reduce(UInt8(0), ^) == bytes[bytes.count - 3] else {
            throw JobError.invalid("Invalid packet framing or checksum for \(step.name)")
        }
        guard !step.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wait.isFinite, wait > 0, wait <= 120, delay.isFinite, delay >= 0, delay <= 120,
              (1...10000).contains(maxAttempts), (step.expect == nil || (0...255).contains(step.expect!)) else {
            throw JobError.invalid("Invalid timing, attempts, or expected command for \(step.name)")
        }
        if step.expect == nil && (expectedData != nil || expectedPrefix != nil || isPolling || step.timeout != nil || step.optional == true) {
            throw JobError.invalid("Response options require expect for \(step.name)")
        }
        if (expectedData != nil && expectedPrefix != nil) || (repeatData != nil && repeatPrefix != nil) ||
           (isPolling && (expectedData != nil || expectedPrefix != nil)) {
            throw JobError.invalid("Use only one payload assertion or polling condition for \(step.name)")
        }
        if isPolling && step.optional == true {
            throw JobError.invalid("Polling cannot be optional: missing completion must fail for \(step.name)")
        }
        if step.maxAttempts != nil && !isPolling {
            throw JobError.invalid("maxAttempts requires a polling condition for \(step.name)")
        }
        if expectedPrefix?.isEmpty == true || repeatPrefix?.isEmpty == true {
            throw JobError.invalid("Payload prefixes must not be empty for \(step.name)")
        }
        for payload in [expectedData, expectedPrefix, repeatData, repeatPrefix].compactMap({ $0 }) {
            guard payload.count <= 255 else { throw JobError.invalid("Response payload is longer than 255 bytes for \(step.name)") }
        }
    }
}

final class NiimbotBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let options: Options
    private let serviceID = CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    private let characteristicID = CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")
    private let steps: [PreparedStep]
    private var central: CBCentralManager!
    private var printer: CBPeripheral?
    private var pipe: CBCharacteristic?
    private var didStart = false
    private var finished = false
    private var exitStatus: Int32 = 1
    private var connectionReady = false
    private var receiveBuffer = Data()
    private var stepIndex = 0
    private var attempt = 0
    private var generation = 0
    private var output = Data()
    private var pumpScheduled = false
    private var fullySent = false
    private var waitingForReply = false
    private var earlyReply: Data?

    init(options: Options, steps: [PreparedStep]) {
        self.options = options
        self.steps = steps
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds + 20 + 120) {
            if !self.finished { self.fail("Overall connection/job timed out") }
        }
    }

    private func fail(_ message: String) { finish(status: 1, message: "ERROR: \(message)") }

    private func finish(status: Int32, message: String) {
        guard !finished else { return }
        finished = true
        exitStatus = status
        generation += 1
        central.stopScan()
        log(message)
        guard let printer, printer.state != .disconnected else { exit(status) }
        central.cancelPeripheralConnection(printer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(status) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished else { return }
        switch central.state {
        case .poweredOn:
            guard !didStart else { return }
            didStart = true
            log("Scanning for \(options.targetDescription) for \(options.scanSeconds) seconds")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) {
                if !self.finished && self.printer == nil { self.fail("Target printer not found within \(self.options.scanSeconds) seconds") }
            }
        case .poweredOff: fail("Bluetooth is powered off")
        case .unauthorized: fail("Bluetooth permission denied for dev.codex.ble-label-printers.niimbot-b21s")
        case .unsupported: fail("Bluetooth LE unsupported")
        case .unknown, .resetting: break
        @unknown default: fail("Unknown Bluetooth state")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard printer == nil, !finished else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard options.matches(id: peripheral.identifier, name: advertisedName ?? peripheral.name) else { return }
        printer = peripheral
        peripheral.delegate = self
        central.stopScan()
        log("Connecting \(peripheral.name ?? advertisedName ?? "unnamed") UUID=\(peripheral.identifier.uuidString) RSSI=\(RSSI)")
        central.connect(peripheral)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if !self.finished && !self.connectionReady { self.fail("Connection/subscription timed out after 20 seconds") }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !finished else { return }
        log("Connected; discovering service")
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Connection failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "clean")")
        if finished { exit(exitStatus) }
        fail("Printer disconnected before job completed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !finished else { return }
        if let error { fail("Service discovery: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            fail("Required NIIMBOT service missing"); return
        }
        peripheral.discoverCharacteristics([characteristicID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !finished else { return }
        if let error { fail("Characteristic discovery: \(error.localizedDescription)"); return }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicID }),
              characteristic.properties.contains(.writeWithoutResponse),
              (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)) else {
            fail("Required NIIMBOT notify/writeWithoutResponse characteristic missing"); return
        }
        pipe = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, characteristic.uuid == characteristicID else { return }
        if let error { fail("Subscription: \(error.localizedDescription)"); return }
        guard characteristic.isNotifying else { fail("Notification subscription not active"); return }
        guard !connectionReady else { return }
        connectionReady = true
        log("Subscribed; write chunk limit=\(min(128, peripheral.maximumWriteValueLength(for: .withoutResponse))) bytes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if !self.finished { self.fail("Job timed out after 120 seconds") }
        }
        beginStep()
    }

    private func beginStep() {
        guard !finished else { return }
        guard stepIndex < steps.count else { finish(status: 0, message: "Job completed: \(steps.count) steps"); return }
        generation += 1
        attempt += 1
        let step = steps[stepIndex]
        log("STEP \(stepIndex + 1)/\(steps.count) \(step.specification.name) attempt=\(attempt)")
        log("TX \(hex(step.packet))")
        output = step.packet
        fullySent = false
        waitingForReply = step.specification.expect != nil
        earlyReply = nil
        pumpOutput()
    }

    private func pumpOutput() {
        guard !finished, let printer, let pipe, !fullySent, !pumpScheduled else { return }
        guard printer.canSendWriteWithoutResponse else { return }
        let count = min(output.count, min(128, printer.maximumWriteValueLength(for: .withoutResponse)))
        guard count > 0 else { fail("Invalid write size"); return }
        let chunk = Data(output.prefix(count))
        output.removeFirst(count)
        printer.writeValue(chunk, for: pipe, type: .withoutResponse)
        if !output.isEmpty {
            pumpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                self.pumpScheduled = false
                self.pumpOutput()
            }
            return
        }
        fullySent = true
        if let data = earlyReply {
            earlyReply = nil
            receivedExpected(data)
        } else if waitingForReply {
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[stepIndex].wait) {
                guard !self.finished, self.generation == token, self.waitingForReply else { return }
                let step = self.steps[self.stepIndex]
                if step.specification.optional ?? false {
                    log("OPTIONAL response timed out for \(step.specification.name)")
                    self.advanceStep()
                } else {
                    self.fail("Response timeout for \(step.specification.name)")
                }
            }
        } else {
            advanceStep()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pumpOutput() }

    private func advanceStep() {
        waitingForReply = false
        generation += 1
        let delay = steps[stepIndex].delay
        stepIndex += 1
        attempt = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.beginStep() }
    }

    private func receivedExpected(_ data: Data) {
        guard !finished, waitingForReply else { return }
        let step = steps[stepIndex]
        waitingForReply = false
        generation += 1
        if let expected = step.expectedData, data != expected {
            fail("\(step.specification.name): expected payload \(hex(expected)), received \(hex(data))"); return
        }
        if let prefix = step.expectedPrefix, !data.starts(with: prefix) {
            fail("\(step.specification.name): expected payload prefix \(hex(prefix)), received \(hex(data))"); return
        }
        let repeatPending = (step.repeatData != nil && data != step.repeatData!) ||
                            (step.repeatPrefix != nil && !data.starts(with: step.repeatPrefix!))
        if repeatPending {
            guard attempt < step.maxAttempts else { fail("\(step.specification.name): completion not reached after \(attempt) attempts"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { self.beginStep() }
        } else {
            advanceStep()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !finished, characteristic.uuid == characteristicID else { return }
        if let error { fail("Notification error: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        log("RX \(hex(data))")
        receiveBuffer.append(data)
        while receiveBuffer.count >= 2 && !finished {
            let bytes = [UInt8](receiveBuffer)
            guard bytes[0] == 0x55, bytes[1] == 0x55 else {
                receiveBuffer.removeFirst(); continue
            }
            guard bytes.count >= 4 else { return }
            let frameLength = Int(bytes[3]) + 7
            guard bytes.count >= frameLength else { return }
            let frame = Array(bytes.prefix(frameLength))
            guard frame[frameLength - 2] == 0xaa, frame[frameLength - 1] == 0xaa,
                  frame[2..<(frameLength - 3)].reduce(UInt8(0), ^) == frame[frameLength - 3] else {
                fail("Malformed response frame/checksum: \(hex(Data(frame)))"); return
            }
            receiveBuffer.removeFirst(frameLength)
            let payload = Data(frame[4..<(frameLength - 3)])
            log(String(format: "FRAME command=%02x payload=%@", frame[2], hex(payload)))
            logStatus(command: frame[2], payload: payload)
            if frame[2] == 0xdb {
                fail("Printer reported print error (DB), payload=\(hex(payload))"); return
            }
            if frame[2] == 0xb3 && frame[3] == 10 && frame[10] != 0 {
                fail("Printer print status reports error code \(frame[10]), payload=\(hex(payload))"); return
            }
            if waitingForReply && stepIndex < steps.count && Int(frame[2]) == steps[stepIndex].specification.expect {
                if fullySent { receivedExpected(payload) } else { earlyReply = payload }
            }
        }
    }
}

// Decode only known fields; always keep raw RX/FRAME logging above.
func logStatus(command: UInt8, payload: Data) {
    let bytes = [UInt8](payload)
    switch command {
    case 0x48 where bytes.count == 2:
        let model = Int(bytes[0]) * 256 + Int(bytes[1])
        log("Model: \(model)\(model == 777 ? " (B21S)" : "")")
    case 0x49 where bytes.count == 2:
        log("Firmware: \(bytes[0]).\(bytes[1])")
    case 0x4a where bytes.count == 1:
        log("Battery level (raw device code): \(bytes[0])")
    case 0x43 where bytes.count == 1:
        log("Label type: \(bytes[0])")
    case 0xb3 where bytes.count >= 4:
        log("Print status: page=\(Int(bytes[0]) * 256 + Int(bytes[1])) printed=\(bytes[2])% fed=\(bytes[3])%")
    default: break
    }
}

let statusJob = """
[
  {"name":"connect","hex":"035555c10101c1aaaa","expect":194,"timeout":3,"delay":0.1},
  {"name":"model","hex":"555540010849aaaa","expect":72,"expectData":"0309","timeout":3,"delay":0.1},
  {"name":"firmware","hex":"555540010948aaaa","expect":73,"optional":true,"timeout":3,"delay":0.1},
  {"name":"battery","hex":"555540010a4baaaa","expect":74,"optional":true,"timeout":3,"delay":0.1},
  {"name":"heartbeat","hex":"5555dc0101dcaaaa","expect":221,"optional":true,"timeout":3,"delay":0.1},
  {"name":"label type","hex":"555540010342aaaa","expect":67,"optional":true,"timeout":3,"delay":0.1},
  {"name":"roll RFID","hex":"55551a01011aaaaa","expect":27,"optional":true,"timeout":3,"delay":0.1}
]
"""

do {
    let options = try parseOptions()
    let input: Data
    let offline: Bool
    switch options.command {
    case .status:
        input = Data(statusJob.utf8)
        offline = false
    case .sendFile(let path):
        input = try Data(contentsOf: URL(fileURLWithPath: path))
        offline = false
    case .validateFile(let path):
        input = try Data(contentsOf: URL(fileURLWithPath: path))
        offline = true
    }
    let specifications = try JSONDecoder().decode([Step].self, from: input)
    guard !specifications.isEmpty else { throw JobError.invalid("Job must contain at least one step") }
    let steps = try specifications.map(PreparedStep.init)
    log("Loaded and validated \(steps.count) job steps")
    if offline { exit(0) }
    let connection = NiimbotBLE(options: options, steps: steps)
    withExtendedLifetime(connection) { RunLoop.main.run() }
} catch {
    fputs("Invalid arguments/job: \(error)\n", stderr)
    exit(2)
}
