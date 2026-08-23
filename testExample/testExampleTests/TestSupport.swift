import Foundation
import Synchronization
import Testing
@testable import testExample

/// Records queries and returns a canned result.
///
/// An actor, not a class-with-a-lock: test doubles are a natural place to
/// demonstrate that actors are the default answer for mutable shared state.
actor SpyGitHubClient: GitHubClient {
    private(set) var queries: [String] = []
    private let result: Result<[Repo], GitHubClientError>

    init(result: Result<[Repo], GitHubClientError>) {
        self.result = result
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        queries.append(query)
        return try result.get()
    }
}

/// Returns a *different* result for each successive call, from a script the
/// test hands it up front.
///
/// `SpyGitHubClient` can only ever answer one way, which makes it useless for
/// anything about *recovery*: "this query fails, then the same query
/// succeeds" is the entire premise of `retry()`. Scripting the sequence
/// instead of mutating a `result` property keeps the test's intent in one
/// readable line at the top and leaves no window in which the double's
/// behaviour depends on when the test got around to reassigning it.
actor ScriptedGitHubClient: GitHubClient {
    private(set) var queries: [String] = []
    private var script: [Result<[Repo], GitHubClientError>]
    private let fallback: Result<[Repo], GitHubClientError>

    /// - Parameters:
    ///   - script: consumed one entry per call, in order.
    ///   - fallback: answers every call after the script runs out, so a test
    ///     that makes one extra call gets a sensible answer rather than a
    ///     crash in the double.
    init(
        script: [Result<[Repo], GitHubClientError>],
        fallback: Result<[Repo], GitHubClientError> = .success([])
    ) {
        self.script = script
        self.fallback = fallback
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        queries.append(query)
        let next = script.isEmpty ? fallback : script.removeFirst()
        return try next.get()
    }
}

/// Suspends every request until the test calls `open()`, letting tests
/// observe in-flight (`.loading`) state deterministically — no sleeps.
///
/// Cancellation is handled explicitly. Without the
/// `withTaskCancellationHandler` below, cancelling a task parked on one of
/// these continuations left it parked *forever*: nothing ever resumed it, so
/// `await task.value` deadlocked and no test could assert anything about the
/// cancellation path. The handler resumes just that call's continuation, and
/// `Task.checkCancellation()` afterwards converts the wake-up into the
/// `CancellationError` a real client would have thrown.
actor GatedGitHubClient: GitHubClient {
    /// Keyed by a per-call ticket so cancellation can resume *one* waiter
    /// without disturbing the others.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let repos: [Repo]

    init(repos: [Repo]) {
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // If cancellation already landed, `onCancel` has run (or is
                // about to run) and will find nothing to release — so resume
                // immediately rather than parking a continuation nobody owns.
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[ticket] = continuation
                }
            }
        } onCancel: {
            Task { await self.release(ticket) }
        }
        // Reached either because `open()` released us or because we were
        // cancelled; only the second leaves the task cancelled.
        try Task.checkCancellation()
        return repos
    }

    func open() {
        for continuation in waiters.values { continuation.resume() }
        waiters.removeAll()
    }

    private func release(_ ticket: UUID) {
        waiters.removeValue(forKey: ticket)?.resume()
    }
}

/// Gated like `GatedGitHubClient`, but deliberately **ignores cancellation**:
/// once `open()` releases it, it returns results whether or not its task was
/// cancelled meanwhile.
///
/// This is not a worse version of `GatedGitHubClient` — it models the client
/// you don't control. Plenty of real async APIs never check
/// `Task.isCancelled`, and `URLSession` itself will happily deliver a response
/// that was already in flight. `SearchViewModel`'s post-`await`
/// `Task.isCancelled` guard exists precisely for that case, and this double is
/// the only way to reach it: against a cancellation-honouring client the
/// `catch is CancellationError` branch fires first and the guard is never
/// exercised.
actor UncancellableGatedGitHubClient: GitHubClient {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let repos: [Repo]

    init(repos: [Repo]) {
        self.repos = repos
    }

    /// Safe from the deadlock that motivated `withTaskCancellationHandler`
    /// elsewhere in this file only because every test that suspends here also
    /// calls `open()`. Do not reach for this double when the scenario is "the
    /// call never completes".
    func searchRepositories(matching query: String) async throws -> [Repo] {
        await withCheckedContinuation { waiters.append($0) }
        return repos
    }

    func open() {
        for continuation in waiters { continuation.resume() }
        waiters.removeAll()
    }

    var isPending: Bool { !waiters.isEmpty }
}

/// Gates calls by query key, and can be armed before a call arrives
/// (`open(_:)` called first) or release one already in flight (`open(_:)`
/// called after). Lets a test run two overlapping searches and control
/// precisely which one resolves first — the shape needed to prove a
/// superseded, still in-flight search cannot clobber a newer search's
/// result once it's finally released.
///
/// Waiters are stored as an *array* per key. The previous
/// `[String: CheckedContinuation]` silently dropped a continuation whenever
/// two calls used the same key — the second `continuations[query] = $0`
/// overwrote the first, and an unresumed `CheckedContinuation` that is
/// discarded is a leaked task plus a runtime warning. Appending and resuming
/// all of them makes same-key reentry safe, which matters now that
/// stale-while-revalidate means a test can legitimately search the same term
/// twice.
///
/// Cancellation is handled the same way as `GatedGitHubClient`; see there.
actor KeyedGatedGitHubClient: GitHubClient {
    /// A parked call. The ticket exists so cancellation can pull one specific
    /// waiter out of the array — `CheckedContinuation` isn't `Equatable`, so
    /// there is no way to find it again without an identity of our own.
    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [String: [Waiter]] = [:]
    private var preOpened: Set<String> = []
    private let repos: [String: [Repo]]

    init(repos: [String: [Repo]]) {
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        if preOpened.remove(query) == nil {
            let ticket = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[query, default: []].append(
                            Waiter(ticket: ticket, continuation: continuation)
                        )
                    }
                }
            } onCancel: {
                Task { await self.release(query, ticket: ticket) }
            }
            try Task.checkCancellation()
        }
        return repos[query] ?? []
    }

    /// Resumes every call for `query` that's already suspended; if none is,
    /// arms the key to resolve immediately the moment a call arrives.
    func open(_ query: String) {
        if let parked = waiters.removeValue(forKey: query), !parked.isEmpty {
            for waiter in parked { waiter.continuation.resume() }
        } else {
            preOpened.insert(query)
        }
    }

    /// True once `searchRepositories(matching: query)` has suspended
    /// waiting for `open(_:)` — lets a test wait for a call to be truly
    /// in flight before proceeding, deterministically.
    func isPending(_ query: String) -> Bool {
        !(waiters[query] ?? []).isEmpty
    }

    private func release(_ query: String, ticket: UUID) {
        guard var parked = waiters[query],
              let index = parked.firstIndex(where: { $0.ticket == ticket })
        else { return }
        let waiter = parked.remove(at: index)
        waiters[query] = parked.isEmpty ? nil : parked
        waiter.continuation.resume()
    }
}

/// A `URLProtocol` that answers every request with a canned response instead
/// of touching the network.
///
/// The technique: register this class on a dedicated `URLSessionConfiguration`
/// (not `.shared`), point `LiveGitHubClient(session:)` at the resulting
/// session, and set `handler` before each call. `URLSession` hands every
/// request for that session to `canInit`/`startLoading` on this type instead
/// of a real socket, so tests exercise `LiveGitHubClient`'s actual response
/// and error handling — status codes, malformed bodies — with no real HTTP
/// traffic and no flakiness from an actual network.
///
/// `handler` is a `Mutex`, not `nonisolated(unsafe) static var`. The old
/// comment justified the unsafe global by pointing at the suite's
/// `.serialized` trait, which was the wrong race entirely: `.serialized` stops
/// two *tests* from overlapping, but the read of `handler` in `startLoading()`
/// happens on a `URLSession` loader thread, concurrently with the test thread
/// writing it in `defer`. No amount of test serialization orders a test
/// against the loader thread it spawned. The `Mutex` orders the actual
/// participants.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let stored = Mutex<Handler?>(nil)

    static var handler: Handler? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No in-flight work to cancel — `startLoading()` above is synchronous.
    }
}

/// Runs `body` against a `LiveGitHubClient` whose session is stubbed by
/// `StubURLProtocol`, then invalidates that session.
///
/// The invalidation is the point. Every `URLSession(configuration:)` spins up
/// its own delegate queue and loader thread and keeps them alive until it is
/// invalidated or deallocated — and a session retains itself while it has
/// outstanding work. A suite that builds one per test and walks away leaks a
/// thread per test. `finishTasksAndInvalidate()` costs one line here and one
/// `defer` for the whole suite.
func withStubbedClient<T>(
    handler: @escaping StubURLProtocol.Handler,
    client body: (LiveGitHubClient) async throws -> T
) async rethrows -> T {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.handler = handler
    defer {
        StubURLProtocol.handler = nil
        session.finishTasksAndInvalidate()
    }
    return try await body(LiveGitHubClient(session: session))
}

extension [Repo] {
    static let fixture: [Repo] = [
        Repo(id: 1, fullName: "apple/swift", ownerLogin: "apple",
             summary: "The Swift Programming Language",
             stargazersCount: 67000, forksCount: 10000,
             language: "C++", htmlURL: URL(string: "https://github.com/apple/swift")!)
    ]
}

/// Thrown by `poll(until:)` when its condition never held.
///
/// `Issue.record` alone was not enough: it marks the test failed but returns
/// normally, so the caller carried on into assertions that could only fail in
/// confusing ways — or, worse, into an `await task.value` that never returned,
/// turning a clear timeout into a hung suite. Recording *and* throwing gives
/// the readable failure message and stops the test where the problem is.
struct PollTimeoutError: Error, CustomStringConvertible {
    let message: String
    var description: String { "Timed out waiting for \(message)" }
}

/// Polls a main-actor condition until it holds or the timeout elapses.
/// Records a test failure and throws on timeout, so callers read linearly and
/// stop at the first thing that didn't happen.
@MainActor
func poll(
    until condition: () -> Bool,
    timeout: Duration = .seconds(2),
    message: @autoclosure () -> String = "condition"
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    // One last look. The loop can exit with the deadline just passed while
    // the condition became true during the final sleep; failing then would be
    // a pure timing artefact.
    if condition() { return }
    Issue.record("Timed out waiting for \(message())")
    throw PollTimeoutError(message: message())
}

/// Same semantics as the synchronous overload above, for conditions that
/// must themselves suspend (e.g. querying an actor). Kept as a distinct
/// overload — rather than making the sync one `async` everywhere — so
/// existing synchronous call sites stay exactly as simple as they were.
@MainActor
func poll(
    until condition: () async -> Bool,
    timeout: Duration = .seconds(2),
    message: @autoclosure () -> String = "condition"
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return }
    Issue.record("Timed out waiting for \(message())")
    throw PollTimeoutError(message: message())
}
