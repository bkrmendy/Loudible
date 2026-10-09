import Foundation

public enum ExporterError: Error, Equatable, Sendable {
    /// No usable credentials: the user must sign in (again).
    case authenticationRequired
    case loginCallback(LoginCallbackError)
    case http(status: Int, message: String?)
    case network(String)
    case malformedResponse(String)
    case licenseDenied(asin: String, reason: String)
    case unsupportedDRM(asin: String, drmType: String)
    case missingDecryptionKey(asin: String)
    case credentialStorage(String)
    case download(String)
    case conversion(String)
    case fileSystem(String)
    case cancelled
    case unexpected(String)

    /// Maps any error to an `ExporterError`, keeping existing ones unchanged.
    public static func from(_ error: any Error) -> ExporterError {
        switch error {
        case let error as ExporterError: error
        case is CancellationError: .cancelled
        case let error as URLError where error.code == .cancelled: .cancelled
        case let error as URLError: .network(error.localizedDescription)
        default: .unexpected(String(describing: error))
        }
    }
}

extension ExporterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Sign in to Audible to continue."
        case .loginCallback(let error):
            switch error {
            case .malformedURL: "The sign-in address is not a valid URL."
            case .unexpectedHost(let host): "The sign-in address points to an unexpected host (\(host ?? "none"))."
            case .unexpectedPath(let path): "The sign-in address has an unexpected path (\(path))."
            case .missingAuthorizationCode: "The sign-in address does not contain an authorization code."
            case .noPendingLogin: "This sign-in is no longer active. Start signing in again."
            case .expired: "This sign-in has expired. Start signing in again."
            }
        case .http(let status, let message):
            "Audible returned HTTP \(status)\(message.map { ": \($0)" } ?? "")."
        case .network(let detail):
            "Network error: \(detail)"
        case .malformedResponse(let detail):
            "Audible returned an unexpected response: \(detail)"
        case .licenseDenied(_, let reason):
            "The download license was denied: \(reason)"
        case .unsupportedDRM(_, let drmType):
            "This title uses unsupported DRM (\(drmType))."
        case .missingDecryptionKey:
            "The download license does not contain a decryption key."
        case .credentialStorage(let detail):
            "Could not access saved credentials: \(detail)"
        case .download(let detail):
            "Download failed: \(detail)"
        case .conversion(let detail):
            "Conversion failed: \(detail)"
        case .fileSystem(let detail):
            "File error: \(detail)"
        case .cancelled:
            "Cancelled."
        case .unexpected(let detail):
            "Unexpected error: \(detail)"
        }
    }
}
