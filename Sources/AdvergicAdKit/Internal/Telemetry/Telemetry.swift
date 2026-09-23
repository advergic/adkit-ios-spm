import Foundation

/// Ships meaningful SDK events to the shared observability collector.
///
/// Separate from `AdvergicLog` and deliberately not a mirror of it. The console is a debugging
/// aid the integrator opts into; this is the production signal, and the interesting case — a
/// publisher whose ads stopped filling in the field — is exactly the one where nobody is watching
/// the console. **So telemetry does not honour `enableLogging`.**
///
/// What gets sent is chosen at the call sites: lifecycle outcomes, fills and their prices, and
/// every failure. Errors flush immediately.
enum Telemetry {

    private struct State {
        var serviceName = "unknown"
        var sessionId = ""
        var resourceAttributes: Attributes = [:]
        var sender: BatchSender<OtlpLogRecord>?
    }

    private static let state = Locked(State())

    /// One run of the host app, so events can be stitched into a session without a device id.
    /// Regenerated per process by design.
    static var sessionId: String { state.get().sessionId }

    /// - Parameter serviceName: The host app's bundle id — what identifies a publisher in the
    ///   collector.
    static func start(
        serviceName: String,
        transport: LogTransport? = nil,
        resourceAttributes: Attributes? = nil
    ) {
        state.mutate { current in
            guard current.sender == nil else { return }

            let sessionId = UUID().uuidString.lowercased()
            var resource = resourceAttributes ?? DeviceContext.staticAttributes()
            resource["session.id"] = .string(sessionId)
            resource.merge(Integration.attributes()) { $1 }
            if resourceAttributes == nil {
                let advertising = DeviceContext.advertisingInfo()
                resource["privacy.limit_ad_tracking"] = .bool(advertising.limitAdTracking)
                if let id = advertising.id { resource["device.advertising_id"] = .string(id) }
            }

            current.serviceName = serviceName
            current.sessionId = sessionId
            current.resourceAttributes = resource
            current.sender = BatchSender(
                label: "telemetry",
                transport: transport ?? HTTPLogTransport(
                    endpoint: Constants.otelEndpoint.trimmingTrailing("/") + Constants.otelLogsPath
                ),
                encode: { batch in
                    // Read at flush time so a later resource update reaches the next batch.
                    let snapshot = state.get()
                    return try OtlpPayload.encode(
                        batch,
                        serviceName: snapshot.serviceName,
                        resourceAttributes: snapshot.resourceAttributes
                    )
                }
            )
        }
    }

    /// Releases the sender. Anything still queued is dropped.
    static func stop() {
        let sender = state.mutate { current -> BatchSender<OtlpLogRecord>? in
            let sender = current.sender
            current = State()
            return sender
        }
        sender?.stop()
    }

    /// Test hook: sends whatever is buffered now.
    static func flush() { state.get().sender?.flush() }

    static func info(
        _ event: String, _ body: String,
        adUnitId: String? = nil, adUnitType: String? = nil, attrs: Attributes = [:]
    ) {
        log(OtlpLogRecord(event: event, severity: .info, body: body,
                          adUnitId: adUnitId, adUnitType: adUnitType, attributes: attrs))
    }

    static func warn(
        _ event: String, _ body: String, error: String? = nil,
        adUnitId: String? = nil, adUnitType: String? = nil, attrs: Attributes = [:]
    ) {
        log(OtlpLogRecord(event: event, severity: .warn, body: body, adUnitId: adUnitId,
                          adUnitType: adUnitType, errorMessage: error, attributes: attrs))
    }

    static func error(
        _ event: String, _ body: String, error: String? = nil,
        adUnitId: String? = nil, adUnitType: String? = nil, attrs: Attributes = [:]
    ) {
        log(OtlpLogRecord(event: event, severity: .error, body: body, adUnitId: adUnitId,
                          adUnitType: adUnitType, errorMessage: error, attributes: attrs))
    }

    /// A paid impression. Sent even though the MMPs receive it: those report to the publisher's
    /// account, and none can answer "is this network paying what its floor claims" across
    /// publishers.
    static func revenue(_ revenue: AdvergicAdRevenue, format: String) {
        var attrs: Attributes = [
            "ad.network": .string(revenue.network),
            "ad.revenue": .string(String(revenue.amount)),
            "ad.currency": .string(revenue.currencyCode),
            "ad.precision": .string(revenue.precision),
        ]
        if let usd = revenue.amountUsd { attrs["ad.revenue.usd"] = .string(String(usd)) }
        info(
            "Impression",
            String(format: "%@ paid %.6f %@ for %@", revenue.network, revenue.amount,
                   revenue.currencyCode, format),
            adUnitId: revenue.adUnitId,
            adUnitType: format,
            attrs: attrs
        )
    }

    /// Non-blocking. Dropped when telemetry is not running.
    static func log(_ record: OtlpLogRecord) {
        state.get().sender?.enqueue(record, urgent: record.severity == .error)
    }
}
