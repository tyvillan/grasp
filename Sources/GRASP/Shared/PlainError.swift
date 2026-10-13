import Foundation

/// A system error, said in a sentence a student can act on. The technical
/// description ("The operation couldn't be completed. Operation not
/// permitted", an `NSError` dump) stays out of the text; it goes to the log.
enum PlainError {
    private static let systemDomains: Set<String> = [
        NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain,
    ]

    /// The device or its network is the problem: offline, blocked, timed out.
    static func isConnectionProblem(_ error: Error) -> Bool {
        if error is URLError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if ns.domain == NSPOSIXErrorDomain {
            // EPERM, ENETDOWN, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EHOSTUNREACH, EPIPE
            return [1, 32, 50, 51, 60, 61, 65].contains(ns.code)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectionProblem(underlying) }
        return false
    }

    /// An error from the system or a library's plumbing, not one of GRASP's
    /// or the account service's own readable messages.
    static func isSystemError(_ error: Error) -> Bool {
        let ns = error as NSError
        return systemDomains.contains(ns.domain)
    }

    /// "Couldn't sync. Check your connection and try again." For GRASP's own
    /// readable errors the text is kept: "Couldn't sync: <what it said>".
    static func message(_ error: Error, couldnt action: String) -> String {
        NSLog("GRASP: couldn't %@: %@", action, String(describing: error))
        if isConnectionProblem(error) {
            return "Couldn't \(action). Check your connection and try again."
        }
        if isSystemError(error) {
            return "Couldn't \(action). Try again, and restart GRASP if it keeps happening."
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // A description that is only a type name or a dump is not for reading.
        if text.isEmpty || text.contains("Error Domain=") || text.contains("UserInfo=") {
            return "Couldn't \(action). Try again, and restart GRASP if it keeps happening."
        }
        return "Couldn't \(action): \(text)"
    }
}
