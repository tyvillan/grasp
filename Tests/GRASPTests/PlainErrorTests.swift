import Testing
import Foundation
@testable import GRASP

@Suite("Plain error messages")
struct PlainErrorTests {
    @Test("the sandbox's 'Operation not permitted' reads as a connection problem")
    func operationNotPermitted() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. Operation not permitted"])
        let text = PlainError.message(error, couldnt: "sync")
        #expect(text == "Couldn't sync. Check your connection and try again.")
        #expect(!text.contains("operation couldn't be completed"))
    }

    @Test("a URL error is a connection problem")
    func urlError() {
        #expect(PlainError.message(URLError(.notConnectedToInternet), couldnt: "import")
                == "Couldn't import. Check your connection and try again.")
    }

    @Test("another system error gets a plain sentence with no technical text")
    func otherSystemError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
                            userInfo: [NSLocalizedDescriptionKey: "You don't have permission to save the file"])
        let text = PlainError.message(error, couldnt: "save")
        #expect(text == "Couldn't save. Try again, and restart GRASP if it keeps happening.")
    }

    @Test("a readable message from GRASP's own errors is kept")
    func ownErrorKept() {
        struct Own: LocalizedError { var errorDescription: String? { "That password is too short." } }
        #expect(PlainError.message(Own(), couldnt: "set the password") == "Couldn't set the password: That password is too short.")
    }

    @Test("a debug dump never reaches the text")
    func dumpHidden() {
        struct Dumpy: LocalizedError {
            var errorDescription: String? { "Error Domain=Foo Code=3 \"x\" UserInfo={a=b}" }
        }
        let text = PlainError.message(Dumpy(), couldnt: "sync")
        #expect(!text.contains("Error Domain"))
    }
}
