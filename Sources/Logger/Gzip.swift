#if canImport(Compression)
import Foundation
import Compression

/// Produces gzip (RFC 1952) containers for rotated log archives.
///
/// Apple's Compression framework emits a *raw* DEFLATE stream for
/// `COMPRESSION_ZLIB` (RFC 1951) with no container around it, so writing a file
/// that `gunzip` and every other standard tool can open means supplying the
/// gzip header and the trailing CRC-32 and length ourselves.
internal enum Gzip {

    /// Returns `data` as a gzip stream, or `nil` if compression fails.
    static func compress(_ data: Data) -> Data? {
        guard let deflated = deflate(data) else { return nil }

        var output = Data(capacity: deflated.count + 18)

        // Header: magic, DEFLATE method, no flags, no mtime, no extra flags,
        // and an unknown OS (255) so the output is reproducible.
        output.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(deflated)

        // Trailer: CRC-32 of the *uncompressed* data, then its length mod 2^32,
        // both little-endian.
        appendLittleEndian(&output, crc32(data))
        appendLittleEndian(&output, UInt32(truncatingIfNeeded: data.count))

        return output
    }

    private static func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        // Incompressible input can grow slightly, so leave headroom rather than
        // letting the encode fail on a tight buffer.
        let capacity = data.count + (data.count / 2) + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, capacity,
                base, data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
#endif
