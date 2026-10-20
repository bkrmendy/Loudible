import Foundation

/// An Audible/Amazon storefront. One marketplace is active at a time.
public struct Marketplace: Sendable, Hashable, Identifiable {
    /// Short country code used by Audible's iOS sign-in handle, e.g. `us`.
    public let id: String
    public let name: String
    /// Top-level domain shared by the Amazon and Audible hosts, e.g. `co.uk`.
    public let domain: String
    /// Amazon marketplace identifier sent during sign-in.
    public let marketplaceID: String

    public init(id: String, name: String, domain: String, marketplaceID: String) {
        self.id = id
        self.name = name
        self.domain = domain
        self.marketplaceID = marketplaceID
    }

    /// Host serving the sign-in pages and the login callback.
    public var amazonHost: String { "www.amazon.\(domain)" }
    /// Host serving device registration and token refresh.
    public var amazonAPIHost: String { "api.amazon.\(domain)" }
    /// Host serving library and license requests.
    public var audibleAPIHost: String { "api.audible.\(domain)" }

    public static let us = Marketplace(id: "us", name: "United States", domain: "com", marketplaceID: "AF2M0KC94RCEA")
    public static let uk = Marketplace(
        id: "uk",
        name: "United Kingdom",
        domain: "co.uk",
        marketplaceID: "A2I9A3Q2GNFNGQ")
    public static let germany = Marketplace(id: "de", name: "Germany", domain: "de", marketplaceID: "AN7V1F1VY261K")
    public static let france = Marketplace(id: "fr", name: "France", domain: "fr", marketplaceID: "A2728XDNODOQ8T")
    public static let italy = Marketplace(id: "it", name: "Italy", domain: "it", marketplaceID: "A2N7FU2W2BU2ZC")
    public static let spain = Marketplace(id: "es", name: "Spain", domain: "es", marketplaceID: "ALMIKO4SZCSAR")
    public static let canada = Marketplace(id: "ca", name: "Canada", domain: "ca", marketplaceID: "A2CQZ5RBY40XE")
    public static let australia = Marketplace(
        id: "au",
        name: "Australia",
        domain: "com.au",
        marketplaceID: "AN7EY7DTAW63G")
    public static let india = Marketplace(id: "in", name: "India", domain: "in", marketplaceID: "AJO3FBRUE6J4S")
    public static let japan = Marketplace(id: "jp", name: "Japan", domain: "co.jp", marketplaceID: "A1QAP3MOU4173J")

    /// Supported marketplaces in display order. US is the default.
    public static let all: [Marketplace] = [
        .us,
        .uk,
        .germany,
        .france,
        .italy,
        .spain,
        .canada,
        .australia,
        .india,
        .japan
    ]

    public static func withID(_ id: String) -> Marketplace? {
        all.first { $0.id == id }
    }
}

extension Marketplace: Codable {
    // Persist only the identifier so stored sessions follow corrected marketplace data.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        guard let marketplace = Marketplace.withID(id) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown marketplace '\(id)'")
        }
        self = marketplace
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
