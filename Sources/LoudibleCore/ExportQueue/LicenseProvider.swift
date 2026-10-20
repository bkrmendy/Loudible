import Foundation

/// Obtains a license through the current authenticated session.
struct LicenseProvider: Sendable {
    let auth: AuthenticationCoordinator
    let api: any AudibleAPI

    func fetch(for book: Audiobook) async throws(ExporterError) -> (ContentLicense, customerID: String) {
        return try await auth.withValidSession { session in
            (try await api.license(for: book.asin, marketplace: book.marketplace, session: session), session.customerID)
        }
    }

}
