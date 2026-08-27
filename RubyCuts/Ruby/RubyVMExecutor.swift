import Foundation

/// The dedicated thread and `SerialExecutor` that ``RubyRuntime`` runs on.
///
/// CRuby records whichever thread calls `rubycuts_init` (via `RUBY_INIT_STACK`,
/// see the shim) as the VM's stack-scanning bounds, and every later eval has
/// to happen from inside that same thread's stack range. Booting on
/// ``RubyVMThread``'s entry frame and then looping forever from that same
/// frame keeps every job's stack strictly inside the range the GC recorded at
/// boot.
///
/// `RubyRuntime` hands this executor jobs (`UnownedJob`s) rather than calling
/// into the VM directly from whatever thread happens to be running -- the
/// executor is what makes "always the VM thread" a compiler-enforced
/// invariant instead of a convention.
nonisolated final class RubyVMExecutor: SerialExecutor {
    private let thread: RubyVMThread

    init() {
        thread = RubyVMThread()
        thread.executor = self
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        thread.enqueue(UnownedJob(job))
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Traps if called from any thread but the VM thread. `assumeIsolated`
    /// calls this to check its assumption; a trap here means something tried
    /// to treat a non-VM thread as the VM thread, which would otherwise
    /// silently corrupt CRuby's GC stack scan rather than fail loudly.
    func checkIsolated() {
        precondition(
            Thread.current === thread,
            "RubyVMExecutor.checkIsolated() called off the VM thread"
        )
    }
}

/// The backing `Thread` for ``RubyVMExecutor``: boots the VM once on its
/// entry frame, then services a FIFO job queue for the life of the process.
///
/// Never joined and never stopped -- the VM is never torn down (see
/// `RubyRuntime.shared`'s doc comment), so the thread outlives every other
/// piece of app state. Holds its owning executor `weak` -- the executor owns
/// the thread, not the other way around, and the thread runs forever
/// regardless, so there's nothing a strong back-reference would buy.
private nonisolated final class RubyVMThread: Thread, @unchecked Sendable {
    weak var executor: RubyVMExecutor?

    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    override init() {
        super.init()
        name = "RubyCuts.VM"
        // The iOS main thread gets 1 MB, secondary threads default to
        // 512 KB -- either would make Ruby's "stack level too deep" trip
        // *earlier* than the current main-thread run. 4 MB gives more
        // headroom than today, on every platform. Must be set before
        // `start()`; `Thread` reads it once at launch.
        stackSize = 4 << 20
    }

    func enqueue(_ job: UnownedJob) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    override func main() {
        guard let executor else {
            preconditionFailure("RubyVMThread started with no executor set")
        }
        let unownedExecutor = executor.asUnownedSerialExecutor()

        // Every job below runs from this frame or deeper -- including the
        // first one, which is always `bootIfNeeded()` via `RubyRuntime`'s
        // first call. That satisfies RUBY_INIT_STACK's requirement that no
        // later eval's stack sit outside the range recorded at boot.
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()

            job.runSynchronously(on: unownedExecutor)
        }
    }
}
