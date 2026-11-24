import Foundation

public enum Base32Error: Error, LocalizedError, Equatable, Sendable {
    case invalidCharacter(Character)
    case invalidLength

    public var errorDescription: String? {
        switch self {
        case .invalidCharacter(let ch):
            "Invalid Base32 character: '\(ch)'."
        case .invalidLength:
            "Invalid Base32 secret length."
        }
    }
}

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data, padded: Bool = false) -> String {
        if data.isEmpty { return "" }

        var output = String()
        output.reserveCapacity(((data.count * 8) + 4) / 5)

        var buffer: UInt32 = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = Int((buffer >> (bitsLeft - 5)) & 0x1F)
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            output.append(alphabet[index])
        }

        if padded {
            let remainder = output.count % 8
            if remainder != 0 {
                output.append(String(repeating: "=", count: 8 - remainder))
            }
        }

        return output
    }

    public static func decode(_ string: String) throws -> Data {
        let cleaned = string
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }

        if cleaned.isEmpty {
            return Data()
        }

        var output = Data()
        output.reserveCapacity((cleaned.count * 5) / 8)

        var buffer: UInt32 = 0
        var bitsLeft = 0

        for ch in cleaned {
            guard let ascii = ch.asciiValue else {
                throw Base32Error.invalidCharacter(ch)
            }
            let val: UInt32
            switch ascii {
            case 65...90: // 'A'...'Z'
                val = UInt32(ascii - 65)
            case 50...55: // '2'...'7'
                val = UInt32(ascii - 50 + 26)
            default:
                throw Base32Error.invalidCharacter(ch)
            }

            buffer = (buffer << 5) | val
            bitsLeft += 5
            if bitsLeft >= 8 {
                let byte = UInt8((buffer >> (bitsLeft - 8)) & 0xFF)
                output.append(byte)
                bitsLeft -= 8
            }
        }

        // Reject non-zero trailing bits only if length makes zero decoded bytes
        if output.isEmpty && !cleaned.isEmpty {
            throw Base32Error.invalidLength
        }

        return output
    }
}
