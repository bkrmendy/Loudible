import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct MarketplaceTests {
    @Test func supportsTheTenPlannedMarketplacesWithUSFirst() {
        #expect(Marketplace.all.map(\.id) == ["us", "uk", "de", "fr", "it", "es", "ca", "au", "in", "jp"])
        #expect(Set(Marketplace.all.map(\.marketplaceID)).count == 10)
    }

    @Test(arguments: [
        (Marketplace.us, "www.amazon.com", "api.amazon.com", "api.audible.com"),
        (Marketplace.uk, "www.amazon.co.uk", "api.amazon.co.uk", "api.audible.co.uk"),
        (Marketplace.australia, "www.amazon.com.au", "api.amazon.com.au", "api.audible.com.au"),
        (Marketplace.japan, "www.amazon.co.jp", "api.amazon.co.jp", "api.audible.co.jp"),
    ])
    func derivesHosts(marketplace: Marketplace, amazon: String, amazonAPI: String, audible: String) {
        #expect(marketplace.amazonHost == amazon)
        #expect(marketplace.amazonAPIHost == amazonAPI)
        #expect(marketplace.audibleAPIHost == audible)
    }

    @Test func encodesAsIdentifierAndRejectsUnknown() throws {
        let data = try JSONEncoder().encode(Marketplace.germany)
        #expect(String(decoding: data, as: UTF8.self) == "\"de\"")
        #expect(try JSONDecoder().decode(Marketplace.self, from: data) == .germany)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Marketplace.self, from: Data("\"xx\"".utf8))
        }
    }
}

@Suite struct SessionTests {
    @Test func clientIDIsHexOfSerialAndDeviceType() {
        let device = DeviceIdentity(serial: "ABC")
        #expect(device.clientID == Data("ABC#A2CZJZGLK2JJVM".utf8).hexString)
        #expect(device.clientID == "414243234132435a4a5a474c4b324a4a564d")
    }

    @Test func refreshIsNeededWithinLeewayOfExpiry() {
        let session = Fixtures.session(expiresAt: Fixtures.referenceDate.addingTimeInterval(600))
        #expect(!session.needsRefresh(at: Fixtures.referenceDate))
        #expect(session.needsRefresh(at: Fixtures.referenceDate.addingTimeInterval(301)))
        #expect(session.needsRefresh(at: Fixtures.referenceDate.addingTimeInterval(601)))
    }

    @Test func audiobookRoundTripsItsMarketplace() throws {
        let book = Fixtures.book("B1", marketplace: .japan)
        #expect(try JSONDecoder().decode(Audiobook.self, from: JSONEncoder().encode(book)) == book)
    }

    @Test func audiobookWithoutMarketplaceDecodesAsUS() throws {
        // Manifests written before the store was recorded.
        let json = #"{"asin": "B1", "title": "Old", "authors": [], "narrators": []}"#
        let book = try JSONDecoder().decode(Audiobook.self, from: Data(json.utf8))
        #expect(book == Audiobook(asin: "B1", marketplace: .us, title: "Old"))
    }

    @Test func sessionRoundTripsThroughCodable() throws {
        let session = Fixtures.session(marketplace: .france)
        let decoded = try JSONDecoder().decode(AudibleSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
    }

    @Test func pendingLoginExpiresAfterLifetime() {
        let login = Fixtures.pendingLogin()
        #expect(!login.isExpired(at: Fixtures.referenceDate.addingTimeInterval(PendingLogin.lifetime)))
        #expect(login.isExpired(at: Fixtures.referenceDate.addingTimeInterval(PendingLogin.lifetime + 1)))
    }
}

@Suite struct HexTests {
    @Test func roundTrips() {
        let data = Data([0x00, 0x7f, 0x80, 0xff])
        #expect(data.hexString == "007f80ff")
        #expect(Data(hexString: "007F80ff") == data)
    }

    @Test(arguments: ["0", "zz", "0g", "abc"])
    func rejectsInvalid(_ text: String) {
        #expect(Data(hexString: text) == nil)
    }
}

@Suite struct ContentLicenseDecryptionTests {
    @Test func fourByteKeyWithoutIVIsAAX() throws {
        let decryption = try ContentLicense.decryption(asin: "B1", drmType: "Adrm", key: Data([1, 2, 3, 4]), iv: nil)
        #expect(decryption == .aax(activationBytes: Data([1, 2, 3, 4])))
    }

    @Test func sixteenByteKeyAndIVIsAAXC() throws {
        let key = Data(repeating: 1, count: 16), iv = Data(repeating: 2, count: 16)
        #expect(try ContentLicense.decryption(asin: "B1", drmType: "ADRM", key: key, iv: iv) == .aaxc(key: key, iv: iv))
    }

    @Test func otherDRMIsUnsupported() {
        #expect(throws: ExporterError.unsupportedDRM(asin: "B1", drmType: "Widevine")) {
            try ContentLicense.decryption(asin: "B1", drmType: "Widevine", key: Data(count: 16), iv: Data(count: 16))
        }
        #expect(throws: ExporterError.unsupportedDRM(asin: "B1", drmType: "none")) {
            try ContentLicense.decryption(asin: "B1", drmType: nil, key: nil, iv: nil)
        }
    }

    @Test func missingKeyIsReported() {
        #expect(throws: ExporterError.missingDecryptionKey(asin: "B1")) {
            try ContentLicense.decryption(asin: "B1", drmType: "Adrm", key: nil, iv: nil)
        }
    }

    @Test func unexpectedKeyShapeIsUnsupported() {
        #expect(throws: ExporterError.self) {
            try ContentLicense.decryption(asin: "B1", drmType: "Adrm", key: Data(count: 16), iv: nil)
        }
    }
}
