import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class AnalyticsTests: XCTestCase {

    override func tearDown() {
        Analytics.stop()
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return parseJSON(try String(contentsOf: url))
    }

    /// Every key path in a JSON object, e.g. `device.screen.width_px`. Array elements are walked
    /// with `[]` so participants' fields are compared too.
    private func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: Set<String>()) { paths, entry in
                let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                paths.insert(path)
                paths.formUnion(keyPaths(entry.value, prefix: path))
            }
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, prefix: prefix + "[]")) }
        default:
            return []
        }
    }

    func testDottedKeysExpandIntoNestedObjects() {
        let nested = EventsPayload.nest(["device.screen.width_px": .int(1170), "device.model": "iPhone15,2", "name": "x"])
        let device = nested["device"] as? [String: Any]
        XCTAssertEqual((device?["screen"] as? [String: Any])?["width_px"] as? Int64, 1170)
        XCTAssertEqual(device?["model"] as? String, "iPhone15,2")
    }

    func testACollisionKeepsTheFlatKeyRatherThanLosingAValue() {
        let nested = EventsPayload.nest(["sdk.wrapper": "unity", "sdk.wrapper.version": "1.0"])
        XCTAssertEqual((nested["sdk"] as? [String: Any])?["wrapper"] as? String, "unity")
        XCTAssertEqual(nested["sdk.wrapper.version"] as? String, "1.0")
    }

    func testTheWrapperVersionIsASiblingNotAChild() {
        Integration.set(name: "unity", version: "0.1.4")
        defer { Integration.reset() }
        let sdk = EventsPayload.nest(Integration.attributes())["sdk"] as? [String: Any]
        XCTAssertEqual(sdk?["wrapper"] as? String, "unity")
        XCTAssertEqual(sdk?["wrapper_version"] as? String, "0.1.4")
    }

    func testTimestampsAreIso8601UtcWithMilliseconds() {
        XCTAssertEqual(EventsPayload.iso8601(1_789_041_612_000), "2026-09-10T12:00:12.000Z")
    }

    func testNumbersStayNumbers() throws {
        let data = try EventsPayload.encode([AnalyticsEvent(name: "ad.revenue", attributes: ["revenue.amount": .double(0.0184)])],
                                            context: [:], sentAtMs: 0)
        let events = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["events"] as? [[String: Any]]
        XCTAssertEqual((events?[0]["revenue"] as? [String: Any])?["amount"] as? Double, 0.0184)
    }

    /// The iOS payload must have the same shape as the Android golden samples, apart from fields
    /// that genuinely differ by platform (os.api_level, carrier, screen density).
    func testAuctionCompletedMatchesTheAndroidWireShape() throws {
        let android = try fixture("02-auction-completed.json")
        let rungs = [
            ResolvedDemand(demand: RemoteDemand(network: .meta, adUnitId: "1203948571_2049581", label: "meta-banner-hi", floor: 0.012, enabled: true),
                           price: 0.0184, isRealBid: true, payload: "p"),
            ResolvedDemand(demand: RemoteDemand(network: .yandex, adUnitId: "R-M-1884412-3", label: "yandex-banner", floor: 0.01, enabled: true),
                           price: 0.015, isRealBid: false, isLearned: true),
        ]
        let transport = CapturingTransport()
        let context: Attributes = [
            "app.build": .int(5), "app.bundle_id": "com.x", "app.version": "0.5",
            "os.name": "iOS", "os.version": "18.0", "session.id": "s",
            "privacy.limit_ad_tracking": false,
            "sdk.name": "advkit-ios", "sdk.version": "0.0.1", "sdk.wrapper": "unity", "sdk.wrapper_version": "0.1.4",
            "device.timezone": "UTC", "device.advertising_id": "x", "device.screen.width_px": .int(1), "device.screen.height_px": .int(1),
            "device.model": "m", "device.locale": "en", "device.brand": "Apple", "device.manufacturer": "Apple",
            "device.is_emulator": false, "network.connection.type": "wifi",
        ]
        Analytics.start(bundleId: "com.x", sessionId: "s", transport: transport, deviceAttributes: context)
        AdChain(placementName: "home_banner", rungs: rungs, request: "banner 320x50").logResult()
        Analytics.flush()

        let ios = transport.json(0)
        let platformOnly: Set<String> = ["os.api_level", "device.screen.density_dpi", "network.carrier"]
        let missing = keyPaths(android).subtracting(keyPaths(ios)).subtracting(platformOnly)
        XCTAssertTrue(missing.isEmpty, "iOS payload lacks: \(missing.sorted())")
    }

    func testEveryAndroidEventSampleHasItsIOSCounterpartFields() throws {
        // Event-level fields per sample, so a renamed attribute on either side fails here.
        let expectations: [(String, Set<String>)] = [
            ("03-ad-fill.json", ["name", "occurredAt", "auction.id", "placement.name", "ad.network", "ad.unit_id",
                                 "chain.tier", "chain.size", "price", "currency", "price_type"]),
            ("04-ad-load-failed.json", ["name", "occurredAt", "auction.id", "placement.name", "ad.network",
                                        "ad.unit_id", "chain.tier", "chain.size", "error.message",
                                        "ad.format"]),
        ]
        for (file, fields) in expectations {
            let event = (try fixture(file)["events"] as? [[String: Any]])?.first ?? [:]
            let androidFields = keyPaths(event).filter { path in
                !keyPaths(event).contains { $0.hasPrefix(path + ".") }
            }
            XCTAssertEqual(androidFields.subtracting(fields), [], file)
        }
    }
}
