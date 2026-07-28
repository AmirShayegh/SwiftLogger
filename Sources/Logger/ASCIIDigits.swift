/// Writes fixed-width zero-padded decimal numbers straight into a byte buffer.
///
/// Every timestamp field — hours, milliseconds, years — has a known width, so
/// the digits can be placed directly rather than going through `String(format:)`
/// or an interpolation that allocates.
internal enum ASCIIDigits {
    private static let zero = UInt8(ascii: "0")

    /// Writes `value` (0...99) as two digits at `index`.
    @inline(__always)
    static func write2(_ value: Int, to buffer: UnsafeMutableBufferPointer<UInt8>, at index: Int) {
        buffer[index] = zero + UInt8(value / 10)
        buffer[index + 1] = zero + UInt8(value % 10)
    }

    /// Writes `value` (0...999) as three digits at `index`.
    @inline(__always)
    static func write3(_ value: Int, to buffer: UnsafeMutableBufferPointer<UInt8>, at index: Int) {
        buffer[index] = zero + UInt8(value / 100)
        buffer[index + 1] = zero + UInt8((value / 10) % 10)
        buffer[index + 2] = zero + UInt8(value % 10)
    }

    /// Writes `value` (0...9999) as four digits at `index`.
    @inline(__always)
    static func write4(_ value: Int, to buffer: UnsafeMutableBufferPointer<UInt8>, at index: Int) {
        buffer[index] = zero + UInt8(value / 1000)
        buffer[index + 1] = zero + UInt8((value / 100) % 10)
        buffer[index + 2] = zero + UInt8((value / 10) % 10)
        buffer[index + 3] = zero + UInt8(value % 10)
    }
}
