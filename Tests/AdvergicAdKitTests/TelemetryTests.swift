import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class TelemetryTests: XCTestCase {

    override func tearDown() {
        Telemetry.stop()
        super.tearDown()
    }

    private func records(_ payload: [String: Any]) -> [[String: Any]] {
        let resourceLogs = payload["resourceLogs"] as? [[String: Any]]
        let scopeLogs = resourceLogs?.first?["scopeLogs"] as? [[String: Any]]
        return scopeLogs?.first?["logRecords"] as? [[String: Any]] ?? []
    }

    private func attribute(_ record: [String: Any], _ key: String) -> [String: Any]? {
        (record["attributes"] as? [[String: Any]])?.first { $0["key"] as? String == key }?["value"] as? [String: Any]
    }

    private func encode(_ records: [OtlpLogRecord], resource: Attributes = [:]) -> [String: Any] {
        let data = try! OtlpPayload.encode(records, serviceName: "com.example.app", resourceAttributes: resource)
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    // MARK: OtlpPayload

    func testBuildsTheResourceEnvelopeTheCollectorExpects() {
        let payload = encode([OtlpLogRecord(event: "E", severity: .info, body: "b")], resource: ["device.model": "iPhone15,2"])
        let resource = ((payload["resourceLogs"] as! [[String: Any]])[0]["resource"] as! [String: Any])["attributes"] as! [[String: Any]]
        let keys = resource.compactMap { $0["key"] as? String }
        XCTAssertEqual(Array(keys.prefix(3)), ["service.name", "service.version", "deployment.environment"])
        XCTAssertTrue(keys.contains("device.model"))
        XCTAssertEqual((resource[0]["value"] as! [String: Any])["stringValue"] as? String, "com.example.app")
        XCTAssertEqual((resource[2]["value"] as! [String: Any])["stringValue"] as? String, "prod")
    }

    func testCarriesTheScopeNameTheOtherAdvergicSdksUse() {
        let payload = encode([])
        let scope = (((payload["resourceLogs"] as! [[String: Any]])[0]["scopeLogs"] as! [[String: Any]])[0]["scope"] as! [String: Any])
        XCTAssertEqual(scope["name"] as? String, "AdvergicSDK")
    }

    func testTimestampsAreNanosecondsAsAString() {
        let record = records(encode([OtlpLogRecord(event: "E", severity: .info, body: "b", timestampMs: 1_700_000_000_123)]))[0]
        XCTAssertEqual(record["timeUnixNano"] as? String, "1700000000123000000")
    }

    func testOptionalAttributesAreOmittedRatherThanSentNull() {
        let record = records(encode([OtlpLogRecord(event: "E", severity: .info, body: "b")]))[0]
        XCTAssertNil(attribute(record, "ad.unit.id"))
        XCTAssertNil(attribute(record, "error.message"))
        XCTAssertEqual(attribute(record, "event.name")?["stringValue"] as? String, "E")
    }

    func testAdAndErrorAttributesAreMappedToTheirOtelKeys() {
        let record = records(encode([OtlpLogRecord(event: "Load Fail", severity: .warn, body: "b",
                                                   adUnitId: "u1", adUnitType: "banner", errorMessage: "no fill")]))[0]
        XCTAssertEqual(attribute(record, "ad.unit.id")?["stringValue"] as? String, "u1")
        XCTAssertEqual(attribute(record, "ad.unit.type")?["stringValue"] as? String, "banner")
        XCTAssertEqual(attribute(record, "error.message")?["stringValue"] as? String, "no fill")
        XCTAssertEqual(record["severityText"] as? String, "WARN")
    }

    func testTypedValuesKeepTheirOtlpTypes() {
        let record = records(encode([OtlpLogRecord(event: "E", severity: .info, body: "b", attributes: [
            "i": .int(7), "d": .double(0.5), "b": .bool(true),
            "a": .array([.string("x")]), "m": .map(["k": .int(1)]),
        ])]))[0]
        XCTAssertEqual(attribute(record, "i")?["intValue"] as? String, "7")
        XCTAssertEqual(attribute(record, "d")?["doubleValue"] as? Double, 0.5)
        XCTAssertEqual(attribute(record, "b")?["boolValue"] as? Bool, true)
        XCTAssertNotNil(attribute(record, "a")?["arrayValue"])
        XCTAssertNotNil(attribute(record, "m")?["kvlistValue"])
    }

    func testABatchTravelsAsSeveralLogRecordsInOneRequest() {
        let batch = (0..<3).map { OtlpLogRecord(event: "E\($0)", severity: .info, body: "b") }
        XCTAssertEqual(records(encode(batch)).count, 3)
    }

    func testQuotesNewlinesUnicodeAndEmojiSurviveTheRoundTrip() {
        let nasty = "He said \"no fill\"\n\t\\ — ünïcødé 🚀"
        let record = records(encode([OtlpLogRecord(event: "E", severity: .error, body: nasty, errorMessage: nasty)]))[0]
        XCTAssertEqual((record["body"] as? [String: Any])?["stringValue"] as? String, nasty)
        XCTAssertEqual(attribute(record, "error.message")?["stringValue"] as? String, nasty)
    }

    func testAnEmptyBatchStillProducesParseableJson() {
        XCTAssertNotNil(encode([])["resourceLogs"])
    }

    // MARK: Sender

    func testAnErrorFlushesWithoutWaitingForTheBatchWindow() {
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "com.example.app", transport: transport, resourceAttributes: [:])
        Telemetry.info("A", "a")
        Telemetry.error("B", "b")
        waitUntil { transport.payloads.count == 1 }
        XCTAssertEqual(records(transport.json(0)).count, 2)
    }

    func testSeveralRecordsArriveInOneRequest() {
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "com.example.app", transport: transport, resourceAttributes: [:])
        (0..<5).forEach { Telemetry.info("E\($0)", "b") }
        Telemetry.flush()
        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(records(transport.json(0)).count, 5)
    }

    func testAFullBatchGoesOutAt25() {
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "com.example.app", transport: transport, resourceAttributes: [:])
        (0..<25).forEach { Telemetry.info("E\($0)", "b") }
        waitUntil { transport.payloads.count == 1 }
        XCTAssertEqual(records(transport.json(0)).count, 25)
    }

    func testTheQueueIsBoundedAndDropsTheOldest() {
        let transport = CapturingTransport()
        let sender = BatchSender<Int>(label: "t", maxBatch: 1000, flushInterval: 60, capacity: 3, transport: transport) {
            try JSONSerialization.data(withJSONObject: $0)
        }
        (1...5).forEach { sender.enqueue($0) }
        sender.flush()
        let sent = (try? JSONSerialization.jsonObject(with: transport.payloads[0])) as? [Int]
        XCTAssertEqual(sent, [3, 4, 5])
    }

    func testLoggingBeforeStartOrAfterStopIsDropped() {
        Telemetry.info("before", "x")
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "s", transport: transport, resourceAttributes: [:])
        Telemetry.stop()
        Telemetry.error("after", "x")
        Telemetry.flush()
        XCTAssertTrue(transport.payloads.isEmpty)
    }

    func testStartIsIdempotent() {
        let first = CapturingTransport()
        let second = CapturingTransport()
        Telemetry.start(serviceName: "s", transport: first, resourceAttributes: [:])
        let session = Telemetry.sessionId
        Telemetry.start(serviceName: "s", transport: second, resourceAttributes: [:])
        XCTAssertEqual(Telemetry.sessionId, session)
        Telemetry.error("E", "x")
        waitUntil { first.payloads.count == 1 }
        XCTAssertTrue(second.payloads.isEmpty)
    }

    func testAFailingTransportDoesNotKillTheSender() {
        let transport = CapturingTransport()
        transport.fail = true
        Telemetry.start(serviceName: "s", transport: transport, resourceAttributes: [:])
        Telemetry.error("one", "x")
        Telemetry.error("two", "x")
        waitUntil { transport.payloads.count == 2 }
    }

    func testTheServiceNameIdentifiesThePublisher() {
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "com.publisher.game", transport: transport, resourceAttributes: [:])
        Telemetry.error("E", "x")
        waitUntil { transport.payloads.count == 1 }
        let resource = ((transport.json(0)["resourceLogs"] as! [[String: Any]])[0]["resource"] as! [String: Any])["attributes"] as! [[String: Any]]
        XCTAssertEqual((resource[0]["value"] as! [String: Any])["stringValue"] as? String, "com.publisher.game")
        let keys = resource.compactMap { $0["key"] as? String }
        XCTAssertTrue(keys.contains("session.id"))
    }

    func testRevenueIsReportedAsAnImpression() {
        let transport = CapturingTransport()
        Telemetry.start(serviceName: "s", transport: transport, resourceAttributes: [:])
        Telemetry.revenue(AdvergicAdRevenue(amount: 0.0123, currencyCode: "USD", amountUsd: 0.0123,
                                            precision: "PRECISE", network: "admob", adUnitId: "u"), format: "banner")
        Telemetry.flush()
        let record = records(transport.json(0))[0]
        XCTAssertEqual(attribute(record, "event.name")?["stringValue"] as? String, "Impression")
        XCTAssertEqual((record["body"] as? [String: Any])?["stringValue"] as? String, "admob paid 0.012300 USD for banner")
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s")
    }
}
