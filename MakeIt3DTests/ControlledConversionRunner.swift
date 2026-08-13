import Foundation
@testable import MakeIt3D

/// A deterministic stand-in for the media pipeline.
///
/// Every invocation remains suspended until a test finishes, fails, or cancels
/// it. That lets scheduler tests inspect the state between jobs without touching
/// AVFoundation, Core ML, or the file writer.
actor ControlledConversionRunner {
    private typealias EventSink = @Sendable (ConversionEvent) -> Void

    private struct Invocation {
        let request: ConversionRequest
        let events: EventSink
        var release: CheckedContinuation<Void, Never>?
        var isReleased = false
        var receivedCancellation = false
    }

    private struct CountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CancellationWaiter {
        let index: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var invocations: [Invocation] = []
    private var invocationWaiters: [CountWaiter] = []
    private var cancellationWaiters: [CancellationWaiter] = []

    func run(
        _ request: ConversionRequest,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void
    ) async {
        let index = register(request: request, events: onEvent)
        onEvent(.started(totalFrames: request.probe.estimatedFrameCount))

        await withTaskCancellationHandler {
            await holdInvocation(at: index)
        } onCancel: {
            Task { await self.receiveCancellation(at: index) }
        }
    }

    func waitForInvocation(count: Int) async {
        guard invocations.count < count else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(CountWaiter(count: count, continuation: continuation))
        }
    }

    func waitForCancellation(of invocation: Int) async {
        let index = invocation - 1
        precondition(index >= 0)
        if invocations.indices.contains(index), invocations[index].receivedCancellation {
            return
        }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(
                CancellationWaiter(index: index, continuation: continuation)
            )
        }
    }

    func invocationCount() -> Int {
        invocations.count
    }

    func sourceNames() -> [String] {
        invocations.map { $0.request.probe.url.deletingPathExtension().lastPathComponent }
    }

    func request(for invocation: Int) -> ConversionRequest {
        invocations[invocation - 1].request
    }

    func receivedCancellation(for invocation: Int) -> Bool {
        invocations[invocation - 1].receivedCancellation
    }

    func sendProgress(
        _ fraction: Double,
        framesDone: Int,
        to invocation: Int
    ) {
        invocations[invocation - 1].events(
            .progress(fraction: fraction, framesDone: framesDone)
        )
    }

    func finish(_ invocation: Int) {
        let index = invocation - 1
        let request = invocations[index].request
        invocations[index].events(.finished(QueueTestFixture.report(for: request)))
        releaseInvocation(at: index)
    }

    func fail(_ invocation: Int, message: String = "Deterministic test failure") {
        let index = invocation - 1
        invocations[index].events(.failed(message))
        releaseInvocation(at: index)
    }

    /// Retained callbacks deliberately allow a test to simulate a broken worker
    /// reporting success after cancellation. The model must ignore that event.
    func sendLateFinish(_ invocation: Int) {
        let index = invocation - 1
        let request = invocations[index].request
        invocations[index].events(.finished(QueueTestFixture.report(for: request)))
    }

    private func register(
        request: ConversionRequest,
        events: @escaping EventSink
    ) -> Int {
        invocations.append(Invocation(request: request, events: events))
        resolveInvocationWaiters()
        return invocations.count - 1
    }

    private func holdInvocation(at index: Int) async {
        if invocations[index].isReleased { return }
        await withCheckedContinuation { continuation in
            if invocations[index].isReleased {
                continuation.resume()
            } else {
                invocations[index].release = continuation
            }
        }
    }

    private func receiveCancellation(at index: Int) {
        guard invocations.indices.contains(index) else { return }
        invocations[index].receivedCancellation = true
        invocations[index].events(.cancelled)
        releaseInvocation(at: index)
        resolveCancellationWaiters(for: index)
    }

    private func releaseInvocation(at index: Int) {
        guard !invocations[index].isReleased else { return }
        invocations[index].isReleased = true
        let continuation = invocations[index].release
        invocations[index].release = nil
        continuation?.resume()
    }

    private func resolveInvocationWaiters() {
        var pending: [CountWaiter] = []
        for waiter in invocationWaiters {
            if invocations.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        invocationWaiters = pending
    }

    private func resolveCancellationWaiters(for index: Int) {
        var pending: [CancellationWaiter] = []
        for waiter in cancellationWaiters {
            if waiter.index == index {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        cancellationWaiters = pending
    }
}
