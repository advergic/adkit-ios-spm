import Foundation

/// Batches records and hands each batch to an encoder and a transport.
///
/// Shared discipline for telemetry and analytics: nothing blocks the caller, nothing throws, a
/// batch goes out at `maxBatch` records or `flushInterval` after its first record, and the queue
/// is bounded — past `capacity` the oldest records are dropped, because a collector that is down
/// must cost bounded memory, not memory that grows until the host app is killed.
final class BatchSender<Record>: @unchecked Sendable {

    typealias Encoder = ([Record]) throws -> Data

    private let queue: DispatchQueue
    private let maxBatch: Int
    private let flushInterval: TimeInterval
    private let capacity: Int
    private let encode: Encoder
    private let transport: LogTransport

    private var buffer: [Record] = []
    private var pendingFlush: DispatchWorkItem?
    private var stopped = false

    init(
        label: String,
        maxBatch: Int = 25,
        flushInterval: TimeInterval = 5,
        capacity: Int = 256,
        transport: LogTransport,
        encode: @escaping Encoder
    ) {
        queue = DispatchQueue(label: "com.advergic.adkit.\(label)")
        self.maxBatch = maxBatch
        self.flushInterval = flushInterval
        self.capacity = capacity
        self.transport = transport
        self.encode = encode
    }

    /// Non-blocking. `urgent` sends whatever is buffered now — for errors, since the batch a
    /// crash is sitting in is the one that otherwise never sends.
    func enqueue(_ record: Record, urgent: Bool = false) {
        queue.async { [self] in
            guard !stopped else { return }
            buffer.append(record)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }

            if urgent || buffer.count >= maxBatch {
                flushLocked()
            } else if pendingFlush == nil {
                let item = DispatchWorkItem { [weak self] in self?.flushLocked() }
                pendingFlush = item
                queue.asyncAfter(deadline: .now() + flushInterval, execute: item)
            }
        }
    }

    /// Sends everything buffered. Test and shutdown hook.
    func flush() {
        queue.sync { flushLocked() }
    }

    /// Drops anything queued and refuses further records.
    func stop() {
        queue.sync {
            stopped = true
            buffer.removeAll()
            pendingFlush?.cancel()
            pendingFlush = nil
        }
    }

    private func flushLocked() {
        pendingFlush?.cancel()
        pendingFlush = nil

        while !buffer.isEmpty {
            let batch = Array(buffer.prefix(maxBatch))
            buffer.removeFirst(batch.count)
            // An encoding bug must not kill the sender and take the rest of the session with it.
            guard let payload = try? encode(batch) else {
                AdvergicLog.w("Could not encode a batch of \(batch.count) record(s); dropped")
                continue
            }
            transport.send(payload) { _ in }
        }
    }
}
