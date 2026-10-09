import Foundation

/// Lenient, read-only view over parsed JSON. Missing keys and type mismatches yield nil,
/// which suits Audible responses whose optional fields come and go.
struct JSON {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }

    init(data: Data) {
        value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    subscript(key: String) -> JSON {
        JSON((value as? [String: Any])?[key])
    }

    var isNull: Bool { value == nil || value is NSNull }

    var string: String? {
        switch value {
        case let string as String: string
        case let number as NSNumber where !Self.isBool(number): number.stringValue
        default: nil
        }
    }

    /// Accepts numbers and numeric strings (Amazon sends `expires_in` as either).
    var int: Int? {
        switch value {
        case let number as NSNumber where !Self.isBool(number): number.intValue
        case let string as String: Int(string)
        default: nil
        }
    }

    var bool: Bool? {
        switch value {
        case let number as NSNumber where Self.isBool(number): number.boolValue
        case let string as String: ["true": true, "false": false][string.lowercased()]
        default: nil
        }
    }

    var array: [JSON]? {
        (value as? [Any])?.map(JSON.init)
    }

    var dictionary: [String: JSON]? {
        (value as? [String: Any])?.mapValues(JSON.init)
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
