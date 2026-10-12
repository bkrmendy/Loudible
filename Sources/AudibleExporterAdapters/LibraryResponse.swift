import Foundation
import AudibleExporterCore

enum LibraryRequest {
    static let responseGroups = [
        "contributors", "customer_rights", "media", "product_attrs", "product_desc", "product_details",
        "product_extended_attrs", "product_plan_details", "product_plans", "relationships", "series", "origin_asin",
    ].joined(separator: ",")

    static func request(page: Int, pageSize: Int, marketplace: Marketplace) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = marketplace.audibleAPIHost
        components.path = "/1.0/library"
        components.queryItems = [
            URLQueryItem(name: "num_results", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "response_groups", value: responseGroups),
            URLQueryItem(name: "image_sizes", value: "500"),
            URLQueryItem(name: "sort_by", value: "-PurchaseDate"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

enum LibraryParser {
    /// Parses a page of the library held in `marketplace`; every book is tagged with it.
    static func page(from data: Data, response: HTTPURLResponse, marketplace: Marketplace) throws(ExporterError) -> LibraryPage {
        try AudibleAPIStatus.check(data: data, response: response)
        let json = JSON(data: data)
        guard let items = json["items"].array else {
            throw .malformedResponse("Library response has no items.")
        }
        let totalCount = response.value(forHTTPHeaderField: "Total-Count").flatMap { Int($0) }
        return LibraryPage(entries: items.compactMap { entry($0, marketplace: marketplace) }, totalCount: totalCount)
    }

    /// Items without an ASIN cannot be exported or deduplicated and are skipped.
    static func entry(_ item: JSON, marketplace: Marketplace) -> LibraryEntry? {
        guard let asin = item["asin"].string, !asin.isEmpty else { return nil }
        let title = item["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? asin
        let book = Audiobook(
            asin: asin,
            marketplace: marketplace,
            title: title,
            subtitle: item["subtitle"].string,
            authors: names(item["authors"]),
            narrators: names(item["narrators"]),
            seriesTitle: item["series"].array?.first?["title"].string,
            publisher: item["publisher_name"].string,
            runtimeMinutes: item["runtime_length_min"].int,
            releaseDate: item["release_date"].string,
            purchaseDate: item["purchase_date"].string.flatMap(parseDate),
            coverImageURL: (item["product_images"]["500"].string ?? item["product_images"].dictionary?.values.compactMap(\.string).first)
                .flatMap(URL.init(string:))
        )
        let relationships = (item["relationships"].array ?? []).map { relationship in
            ProductRelationship(
                asin: relationship["asin"].string,
                direction: relationship["relationship_to_product"].string.flatMap { ProductRelationship.Direction(rawValue: $0.lowercased()) },
                type: relationship["relationship_type"].string
            )
        }
        return LibraryEntry(
            book: book,
            contentDeliveryType: item["content_delivery_type"].string,
            contentType: item["content_type"].string,
            isAYCE: item["is_ayce"].bool,
            relationships: relationships
        )
    }

    private static func names(_ json: JSON) -> [String] {
        (json.array ?? []).compactMap { $0["name"].string }.filter { !$0.isEmpty }
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Status handling shared by Audible API responses.
enum AudibleAPIStatus {
    static func check(data: Data, response: HTTPURLResponse) throws(ExporterError) {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        if status == 401 { throw .authenticationRequired }
        let json = JSON(data: data)
        throw .http(status: status, message: json["message"].string ?? json["error_description"].string)
    }
}
