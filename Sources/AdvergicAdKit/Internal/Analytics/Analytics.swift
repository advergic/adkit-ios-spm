import Foundation

/// Reports what the mediation actually did: which networks competed, what they were worth, which
/// one served, and what it paid.
///
/// Separate from `Telemetry`, which explains failures to us. This explains revenue to the
/// publisher, goes to a different endpoint in a different format, and can change shape without
/// disturbing the operational stream. Same discipline: never blocks, never throws, bounded.
enum Analytics {

    private struct State {
        var context: Attributes = [:]
        var sender: BatchSender<AnalyticsEvent>?
    }

    private static let state = Locked(State())

    /// - Parameter sessionId: Shared with telemetry so an event here lines up with a failure there.
    static func start(
        bundleId: String,
        sessionId: String,
        transport: LogTransport? = nil,
        deviceAttributes: Attributes? = nil
    ) {
        state.mutate { current in
            guard current.sender == nil else { return }

            var context = deviceAttributes ?? DeviceContext.staticAttributes()
            context.merge(Integration.attributes()) { $1 }
            context["app.bundle_id"] = .string(bundleId)
            context["session.id"] = .string(sessionId)
            if deviceAttributes == nil {
                let advertising = DeviceContext.advertisingInfo()
                context["privacy.limit_ad_tracking"] = .bool(advertising.limitAdTracking)
                if let id = advertising.id { context["device.advertising_id"] = .string(id) }
            }

            current.context = context
            current.sender = BatchSender(
                label: "analytics",
                transport: transport ?? HTTPLogTransport(endpoint: Constants.eventsEndpoint),
                encode: { batch in
                    try EventsPayload.encode(batch, context: state.get().context)
                }
            )
        }
    }

    static func stop() {
        let sender = state.mutate { current -> BatchSender<AnalyticsEvent>? in
            let sender = current.sender
            current = State()
            return sender
        }
        sender?.stop()
    }

    static func flush() { state.get().sender?.flush() }

    /// Non-blocking. Dropped when analytics is not running.
    static func track(_ name: String, _ attrs: Attributes = [:]) {
        state.get().sender?.enqueue(AnalyticsEvent(name: name, attributes: attrs))
    }
}
