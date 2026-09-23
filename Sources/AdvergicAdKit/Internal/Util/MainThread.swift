import Foundation

/// Delivers integrator callbacks on the main thread.
///
/// Runs inline when already there, so a callback fired from a main-thread path is not deferred
/// to the next run-loop turn — the same contract as the Android SDK's `MainThread.post`.
enum MainThread {

    static func post(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    static func postDelayed(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}
