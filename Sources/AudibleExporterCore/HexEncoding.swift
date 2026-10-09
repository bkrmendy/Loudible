import Foundation

extension Data {
    /// Lowercase hexadecimal representation.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes a hexadecimal string. Returns nil for odd lengths or non-hex characters.
    public init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
