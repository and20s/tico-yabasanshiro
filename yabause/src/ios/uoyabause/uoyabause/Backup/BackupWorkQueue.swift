import Foundation

/// Serializes every LocalBackupRepository call.
///
/// It lives in its own file because both the local and the cloud view models
/// have to share the one queue: the backup C API keeps a single process-wide
/// standalone session, so two overlapping repository calls would make the
/// second throw BackupSessionError.alreadyOpen. Any code that touches
/// LocalBackupRepository must therefore go through BackupWorkQueue.shared.
///
/// Because the bodies handed to run() are synchronous, the actor never
/// suspends inside one and therefore gives strict mutual exclusion, while
/// still running the work off the main thread.
actor BackupWorkQueue {
    static let shared = BackupWorkQueue()

    func run<T>(_ body: @Sendable () throws -> T) async rethrows -> T {
        try body()
    }
}
