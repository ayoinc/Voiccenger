import Foundation

/// Hardware and OS facts about this Mac that decide which features can run.
public struct MachineInfo: Sendable, Hashable, Codable {
    /// macOS version, e.g. 26.0.1.
    public var osMajor: Int
    public var osMinor: Int
    public var osPatch: Int
    /// The Mac's CPU: Apple silicon (true also when this process runs translated under Rosetta) or Intel.
    public var isAppleSilicon: Bool
    /// This process is an x86_64 binary translated by Rosetta 2 on Apple silicon.
    public var isTranslated: Bool
    /// Architecture this process runs as: "arm64" or "x86_64".
    public var processArchitecture: String
    /// e.g. "Apple M3 Pro" or "Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz".
    public var cpuName: String
    /// e.g. "Mac15,6" or "Macmini8,1".
    public var modelIdentifier: String
    /// Installed memory in bytes.
    public var physicalMemory: UInt64
    public var processorCount: Int

    public init(
        osMajor: Int, osMinor: Int, osPatch: Int = 0, isAppleSilicon: Bool, isTranslated: Bool = false,
        processArchitecture: String, cpuName: String = "", modelIdentifier: String = "",
        physicalMemory: UInt64, processorCount: Int = 8
    ) {
        self.osMajor = osMajor
        self.osMinor = osMinor
        self.osPatch = osPatch
        self.isAppleSilicon = isAppleSilicon
        self.isTranslated = isTranslated
        self.processArchitecture = processArchitecture
        self.cpuName = cpuName
        self.modelIdentifier = modelIdentifier
        self.physicalMemory = physicalMemory
        self.processorCount = processorCount
    }

    public static let current: MachineInfo = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return MachineInfo(
            osMajor: os.majorVersion, osMinor: os.minorVersion, osPatch: os.patchVersion,
            isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
            isTranslated: sysctlInt("sysctl.proc_translated") == 1,
            processArchitecture: architecture,
            cpuName: sysctlString("machdep.cpu.brand_string") ?? "",
            modelIdentifier: sysctlString("hw.model") ?? "",
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount)
    }()

    /// Every Apple silicon Mac has a Neural Engine; Intel Macs have none.
    public var hasNeuralEngine: Bool { isAppleSilicon }

    public var osVersionString: String {
        osPatch > 0 ? "\(osMajor).\(osMinor).\(osPatch)" : "\(osMajor).\(osMinor)"
    }

    public var memoryGigabytes: Double { Double(physicalMemory) / 1_073_741_824 }

    public func osAtLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        (osMajor, osMinor) >= (major, minor)
    }

    /// "Apple silicon", "Apple silicon (Rosetta)" or "Intel".
    public var chipDescription: String {
        guard isAppleSilicon else { return "Intel" }
        return isTranslated ? "Apple silicon (running under Rosetta)" : "Apple silicon"
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
