import Foundation

/// One number the user types on the Watch: the Mac's local address, the
/// short pairing code, and a check digit. Digits only, so the Watch can use a
/// plain keypad and catch a typo before trying the network.
///
///   [range][host digits][4-digit code][check]
///   range 1 = 192.168.x.y (5 host digits)   2 = 10.x.y.z (8)
///         3 = 172.16–31.x.y (7)             9 = any other IPv4 (10)
enum PairingNumber {
    static let codeLength = 4

    static func encode(address: String, code: String) -> String? {
        guard code.count == codeLength, code.allSatisfy(\.isNumber),
              let parts = octets(of: address) else { return nil }
        // 64-bit on purpose: Int is 32 bits on Apple Watch.
        let octets = parts.map(UInt64.init)
        let body: String
        if octets[0] == 192, octets[1] == 168 {
            body = "1" + pad(octets[2] << 8 | octets[3], 5)
        } else if octets[0] == 10 {
            body = "2" + pad(octets[1] << 16 | octets[2] << 8 | octets[3], 8)
        } else if octets[0] == 172, (16...31).contains(octets[1]) {
            body = "3" + pad((octets[1] - 16) << 16 | octets[2] << 8 | octets[3], 7)
        } else {
            body = "9" + pad(octets[0] << 24 | octets[1] << 16 | octets[2] << 8 | octets[3], 10)
        }
        let payload = body + code
        return payload + String(checkDigit(payload))
    }

    static func decode(_ input: String) -> (address: String, code: String)? {
        let digits = input.filter(\.isNumber)
        guard let expected = expectedLength(digits), digits.count == expected else { return nil }
        let payload = String(digits.dropLast())
        guard let last = digits.last?.wholeNumberValue, last == checkDigit(payload) else { return nil }
        let code = String(payload.suffix(codeLength))
        guard let value = UInt64(payload.dropFirst().dropLast(codeLength)) else { return nil }
        let address: String
        switch digits.first {
        case "1":
            guard value <= 0xFFFF else { return nil }
            address = "192.168.\(value >> 8).\(value & 255)"
        case "2":
            guard value <= 0xFF_FFFF else { return nil }
            address = "10.\(value >> 16).\(value >> 8 & 255).\(value & 255)"
        case "3":
            guard value <= 0xF_FFFF else { return nil }
            address = "172.\(16 + (value >> 16)).\(value >> 8 & 255).\(value & 255)"
        default:
            guard value <= 0xFFFF_FFFF else { return nil }
            address = "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
        }
        return (address, code)
    }

    /// Total digits for a number starting with this range digit; nil while
    /// empty or when the first digit is not a valid range.
    static func expectedLength(_ digits: String) -> Int? {
        let host: Int
        switch digits.first {
        case "1": host = 5
        case "2": host = 8
        case "3": host = 7
        case "9": host = 10
        default: return nil
        }
        return 1 + host + codeLength + 1
    }

    /// "1002 6493 398" — groups of four for reading and typing.
    static func grouped(_ digits: String) -> String {
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, index % 4 == 0 { result.append(" ") }
            result.append(character)
        }
        return result
    }

    static func octets(of address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return values.count == 4 ? values : nil
    }

    private static func pad(_ value: UInt64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// Luhn: catches any single wrong digit and most swapped neighbours.
    private static func checkDigit(_ payload: String) -> Int {
        var sum = 0
        for (index, character) in payload.reversed().enumerated() {
            var digit = character.wholeNumberValue ?? 0
            if index % 2 == 0 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return (10 - sum % 10) % 10
    }
}
