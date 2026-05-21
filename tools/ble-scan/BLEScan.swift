import CoreBluetooth
import Foundation

struct Options {
    var scanSeconds: TimeInterval = 15
    var connectNeedle: String?
    var serviceFilter: [CBUUID]?
}

func usage() -> Never {
    fputs("""
    Usage: ble-scan [--scan-seconds SECONDS] [--connect NAME_OR_UUID] [--service UUID]

    Examples:
      ble-scan --scan-seconds 15
      ble-scan --scan-seconds 20 --connect PT-N25BT
      ble-scan --service FF00 --connect PT-N25BT

    """, stderr)
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--scan-seconds":
            guard let value = args.first, let seconds = Double(value) else { usage() }
            args.removeFirst()
            options.scanSeconds = seconds
        case "--connect":
            guard let value = args.first else { usage() }
            args.removeFirst()
            options.connectNeedle = value.lowercased()
        case "--service":
            guard let value = args.first else { usage() }
            args.removeFirst()
            options.serviceFilter = (options.serviceFilter ?? []) + [CBUUID(string: value)]
        case "--help", "-h":
            usage()
        default:
            usage()
        }
    }

    return options
}

func hex(_ data: Data?) -> String {
    guard let data else { return "" }
    return data.map { String(format: "%02x", $0) }.joined()
}

func logLine(_ message: String) {
    print(message)
    fflush(stdout)
}

func describeProperties(_ properties: CBCharacteristicProperties) -> String {
    var names: [String] = []
    if properties.contains(.broadcast) { names.append("broadcast") }
    if properties.contains(.read) { names.append("read") }
    if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
    if properties.contains(.write) { names.append("write") }
    if properties.contains(.notify) { names.append("notify") }
    if properties.contains(.indicate) { names.append("indicate") }
    if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
    if properties.contains(.extendedProperties) { names.append("extendedProperties") }
    if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
    if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
    return names.joined(separator: ",")
}

final class BLEInspector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let options: Options
    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var printedPeripherals = Set<UUID>()
    private var didStartScan = false

    init(options: Options) {
        self.options = options
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            logLine("Bluetooth is powered off")
            exit(1)
        case .unauthorized:
            logLine("Bluetooth access is unauthorized for this tool")
            exit(1)
        case .unsupported:
            logLine("Bluetooth LE is unsupported on this Mac")
            exit(1)
        case .resetting, .unknown:
            break
        @unknown default:
            logLine("Unknown Bluetooth state: \(central.state.rawValue)")
            exit(1)
        }
    }

    private func startScan() {
        guard !didStartScan else { return }
        didStartScan = true

        let serviceText = options.serviceFilter?.map(\.uuidString).joined(separator: ",") ?? "any"
        logLine("Scanning for \(Int(options.scanSeconds))s, services=\(serviceText)")
        central.scanForPeripherals(
            withServices: options.serviceFilter,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) {
            self.central.stopScan()
            if self.connectedPeripheral == nil {
                logLine("Scan complete")
                exit(0)
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
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflowUUIDs = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber
        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber

        if !printedPeripherals.contains(peripheral.identifier) {
            printedPeripherals.insert(peripheral.identifier)
            logLine("")
        }

        logLine("Device name=\"\(name)\" id=\(peripheral.identifier.uuidString) rssi=\(RSSI) connectable=\(connectable?.stringValue ?? "?") tx=\(txPower?.stringValue ?? "?")")
        if let localName, localName != name {
            logLine("  localName=\"\(localName)\"")
        }
        if !serviceUUIDs.isEmpty {
            logLine("  serviceUUIDs=\(serviceUUIDs.map(\.uuidString).joined(separator: ","))")
        }
        if !overflowUUIDs.isEmpty {
            logLine("  overflowServiceUUIDs=\(overflowUUIDs.map(\.uuidString).joined(separator: ","))")
        }
        if manufacturer != nil {
            logLine("  manufacturer=\(hex(manufacturer))")
        }
        for (uuid, data) in serviceData.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            logLine("  serviceData[\(uuid.uuidString)]=\(hex(data))")
        }

        guard let needle = options.connectNeedle, connectedPeripheral == nil else { return }
        let haystacks = [name.lowercased(), peripheral.identifier.uuidString.lowercased()]
        if haystacks.contains(where: { $0.contains(needle) }) {
            logLine("Connecting to name=\"\(name)\" id=\(peripheral.identifier.uuidString)")
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logLine("Connected: \(peripheral.name ?? "(unnamed)") id=\(peripheral.identifier.uuidString)")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logLine("Connect failed: \(error?.localizedDescription ?? "unknown error")")
        exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logLine("Disconnected: \(error?.localizedDescription ?? "no error")")
        exit(error == nil ? 0 : 1)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logLine("Discover services failed: \(error.localizedDescription)")
            exit(1)
        }

        guard let services = peripheral.services, !services.isEmpty else {
            logLine("No services discovered")
            exit(0)
        }

        for service in services {
            logLine("Service \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logLine("Discover characteristics failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            logLine("  Char \(characteristic.uuid.uuidString) props=\(describeProperties(characteristic.properties))")
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }

        if let services = peripheral.services,
           services.allSatisfy({ $0.characteristics != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logLine("    Read \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            return
        }
        logLine("    Read \(characteristic.uuid.uuidString)=\(hex(characteristic.value))")
    }
}

logLine("Starting ble-scan")
var inspector: BLEInspector? = BLEInspector(options: parseOptions())
RunLoop.main.run()
