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
        // Parity with the gated doubles below, which all check the flag before
        // handing anything back. A real client does not answer an
        // already-cancelled task just because its answer was ready — and a
        // double that did would let a view model's cancellation handling pass
        // a test it should fail. It also stops a superseded call from silently
        // eating a script entry the test is counting on for the next search.
        try Task.checkCancellation()
        queries.append(query)
        let next = script.isEmpty ? fallback : script.removeFirst()
        return try next.get()
    }
}

/// Throws `CancellationError` from a task that was never cancelled.
///
/// Not a contrived double. `LiveGitHubClient` maps every
/// `URLError(.cancelled)` to `CancellationError`, and `URLSession` raises
/// that code for reasons that have nothing to do with `Task` cancellation —
/// an invalidated session, a torn-down background configuration, an
/// authentication challenge the delegate refused. From the view model's side
/// those are ordinary failures wearing cancellation's clothes, and this
/// double is how a test can say so.
actor RogueCancellationGitHubClient: GitHubClient {
    private(set) var queries: [String] = []
    private var thrown = 0
    private let failures: Int
    private let repos: [Repo]

    /// - Parameter failures: how many leading calls throw `CancellationError`
    ///   before the client starts succeeding.
    init(failures: Int = 1, repos: [Repo] = .fixture) {
        self.failures = failures
        self.repos = repos
    }

    func searchRepositories(matching query: String) async throws -> [Repo] {
        queries.append(query)
        if thrown < failures {
            thrown += 1
            throw CancellationError()
        }
        return repos
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
/// `Task.isCancelled` guard is what stands between that late success and the
/// screen, and a client that *does* honour cancellation can never reach it:
/// it throws instead of returning. This double is the only way in.
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
    /// A *set*, not a count: arming a key is idempotent. Calling `open(_:)` N
    /// times with no waiter parked arms exactly one future call, and the first
    /// call for that key consumes the arming. Tests that need N calls to sail
    /// through must open the key N times *after* each one has suspended.
    private var preOpened: Set<String> = []
    private let repos: [String: [Repo]]
    /// Per-query outcome scripts, consumed one entry per call that gets past
    /// the gate.
    ///
    /// Gating and scripting have to be the same double for one scenario: the
    /// stale-results promotion is only observable *while a retry of the same
    /// query is in flight*, which needs a query that first succeeds, then
    /// fails, then suspends on demand. `ScriptedGitHubClient` can sequence
    /// outcomes but not suspend; the gate could suspend but only ever
    /// succeed.
    private var scripts: [String: [Result<[Repo], GitHubClientError>]]

    /// - Parameters:
    ///   - repos: the answer for a query with no script entry left.
    ///   - scripts: per-query outcomes, in order, consumed one per call.
    init(
        repos: [String: [Repo]] = [:],
        scripts: [String: [Result<[Repo], GitHubClientError>]] = [:]
    ) {
        self.repos = repos
        self.scripts = scripts
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
        }
        // Outside the `if`, so the pre-armed path checks cancellation too. A
        // real client never hands results to an already-cancelled task just
        // because the response happened to be ready; a double that did would
        // let a view model's cancellation handling pass a test it should fail.
        try Task.checkCancellation()

        if var remaining = scripts[query], !remaining.isEmpty {
            let next = remaining.removeFirst()
            scripts[query] = remaining
            return try next.get()
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
/// `handler` is a `Mutex`, not `nonisolated(unsafe) static var`, and the two
/// mechanisms guarding it answer two different questions.
///
/// The `Mutex` removes the *data* race: the read of `handler` in
/// `startLoading()` happens on a `URLSession` loader thread, concurrently with
/// the test thread writing it. Serializing a suite's tests does not order a
/// test against the loader thread it spawned; the lock does.
///
/// What the lock does **not** decide is *which* handler answers *which*
/// request — `handler` is one process-wide slot, so two overlapping
/// `withStubbedClient` calls would each see a well-defined value that simply
/// belonged to the other test. That is what `StubHandlerGate` below is for.
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

/// Serializes ownership of `StubURLProtocol.handler`, which is one slot for
/// the whole process.
///
/// A `.serialized` trait only orders tests *within* one suite; Swift Testing
/// runs suites concurrently, so a second suite reaching for a stubbed client
/// would install its handler over the first's — each read well-defined, and
/// each answering the wrong test. Holding this gate across a whole
/// `withStubbedClient` call makes "I own the handler" true process-wide for
/// that call's duration.
///
/// Shaped as `acquire()`/`release()` rather than a `run { }` wrapper on
/// purpose: a generic `run<T>` would have to send the body across the actor
/// boundary and return `T` back out, which requires `T: Sendable` and the
/// closure to be `@Sendable`. The bodies here legitimately produce
/// non-`Sendable` values and capture the calling test's state, so the lock is
/// taken *around* them instead of wrapping them.
actor StubHandlerGate {
    static let shared = StubHandlerGate()

    /// True for the duration of a `withStubbedClient` body, and inherited by
    /// anything that body awaits.
    ///
    /// A non-reentrant lock plus a nested acquire is a deadlock, and a
    /// deadlock in a test suite is the worst failure mode available: no
    /// message, no failing assertion, just a run that never ends and a CI job
    /// killed by its own timeout an hour later. A task-local carries the fact
    /// "this task already owns the gate" down into nested calls, so a
    /// `withStubbedClient` inside a `withStubbedClient` fails *at the second
    /// call*, naming itself.
    @TaskLocal static var isHolding = false

    /// How long a caller waits before deciding the gate is never coming.
    /// Generous — the longest legitimate hold is one stubbed request — and
    /// finite, which is the point.
    static let acquireTimeout: Duration = .seconds(30)

    private struct Waiter {
        let ticket: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held = false
    private var waiters: [Waiter] = []

    /// - Returns: `true` if this caller now owns the gate and must release it,
    ///   `false` if it gave up waiting (having recorded an issue). A caller
    ///   that gets `false` must **not** release: the gate belongs to someone
    ///   else, and releasing would hand it to a third party.
    func acquire() async -> Bool {
        precondition(
            !Self.isHolding,
            "StubHandlerGate.acquire() re-entered from inside a withStubbedClient body; "
                + "this gate is not reentrant and waiting on it here would deadlock."
        )
        guard held else {
            held = true
            return true
        }

        let ticket = UUID()
        // The deadline lives outside the continuation because a
        // `CheckedContinuation` cannot be raced against a timer directly —
        // whoever resumes it first wins, so the timer's job is to *be* one of
        // the resumers.
        let deadline = Task {
            try? await Task.sleep(for: Self.acquireTimeout)
            await self.expire(ticket)
        }
        let acquired = await withCheckedContinuation { continuation in
            waiters.append(Waiter(ticket: ticket, continuation: continuation))
        }
        deadline.cancel()

        if !acquired {
            Issue.record(
                """
                Timed out after \(Self.acquireTimeout) waiting for StubHandlerGate. \
                Some other test is holding the process-wide \
                StubURLProtocol.handler slot and never released it.
                """
            )
        }
        return acquired
    }

    /// Hands ownership straight to the next waiter rather than clearing
    /// `held`, so a waiter cannot be barged by a caller that arrives while it
    /// is waking up.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Wakes one waiter empty-handed. Ownership is untouched: the holder still
    /// holds it, and the next `release()` still goes to whoever is left.
    private func expire(_ ticket: UUID) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Runs `body` against a `LiveGitHubClient` whose session is stubbed by
/// `StubURLProtocol`, then invalidates that session.
///
/// Two things happen around `body`. The gate gives this call exclusive
/// ownership of the process-wide `StubURLProtocol.handler` slot for its whole
/// duration, so no concurrently running suite can answer this test's requests.
///
/// The invalidation is the second. Every `URLSession(configuration:)` spins up
/// its own delegate queue and loader thread and keeps them alive until it is
/// invalidated or deallocated — and a session retains itself while it has
/// outstanding work. A suite that builds one per test and walks away leaks a
/// thread per test. `finishTasksAndInvalidate()` costs one line here.
func withStubbedClient<T>(
    handler: @escaping StubURLProtocol.Handler,
    client body: (LiveGitHubClient) async throws -> T
) async throws -> T {
    let owned = await StubHandlerGate.shared.acquire()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.handler = handler

    // Captured rather than rethrown immediately: releasing the gate is an
    // `await`, and `defer` bodies cannot suspend. Funnelling both outcomes
    // through one `Result` keeps the teardown on exactly one path.
    //
    // The body runs inside the task-local that marks this task as the holder,
    // so a nested `withStubbedClient` trips the precondition in `acquire()`
    // instead of waiting for a gate its own caller is holding.
    let outcome: Result<T, any Error>
    do {
        let value = try await StubHandlerGate.$isHolding.withValue(true) {
            try await body(LiveGitHubClient(session: session))
        }
        outcome = .success(value)
    } catch {
        outcome = .failure(error)
    }

    StubURLProtocol.handler = nil
    session.finishTasksAndInvalidate()
    // Only if we actually got it. Releasing a gate we never acquired would
    // hand the real holder's exclusivity to a third caller.
    if owned {
        await StubHandlerGate.shared.release()
    }

    return try outcome.get()
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
