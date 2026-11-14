
// Compiled in the same module as the pinned MIT-licensed ipb UniversalHID glue.
// Keep the Apple HIDReport ABI and ownership in that module, outside the CLI.
@_cdecl("manzanero_make_raw_report")
public func manzaneroMakeRawReport(_ bytes: UnsafePointer<UInt8>?, _ count: Int,
                                     _ output: UnsafeMutableRawPointer?) -> Int32 {
    guard let bytes, let output, count == 58 else { return -1 }
    let payload = Array(UnsafeBufferPointer(start: bytes, count: count))
    guard payload[0] == 9 else { return -1 }
    var report = reportFromBytes(payload, bitCount: digitizerReportBitCount, reportID: 9)
    retainedHIDReports.append(report)
    withUnsafeBytes(of: &report) { output.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return Int32(MemoryLayout<UHIDHIDReport>.size)
}
