import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GRASP

/// A transport that answers from the test, over a fixed URL protocol, so the
/// request shape and status handling are checked with no network.
private nonisolated final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            request.httpBody = data
        }
        Self.seen.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Feedback", .serialized)
@MainActor
struct FeedbackTests {
    // MARK: Helpers

    private func defaults() -> UserDefaults {
        let name = "feedback-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let context = FeedbackContext(
        appVersion: "0.1.0", build: "1", platform: "mac", osVersion: "macOS 27.0",
        deviceModel: "Mac15,6", screen: "Deck > Questions", aiMode: "cloud", installId: "install-1")

    private func draft(_ message: String = "The Add menu was hard to find.") -> FeedbackDraft {
        var d = FeedbackDraft()
        d.type = .confusing
        d.message = message
        return d
    }

    private func makeService(_ transport: StubFeedbackTransport = StubFeedbackTransport(),
                             queue: MemoryFeedbackQueue = MemoryFeedbackQueue(),
                             defaults: UserDefaults? = nil,
                             now: @escaping () -> Date = Date.init) -> (FeedbackService, StubFeedbackTransport, MemoryFeedbackQueue, UserDefaults) {
        let d = defaults ?? self.defaults()
        return (FeedbackService(transport: transport, queue: queue, defaults: d, now: now), transport, queue, d)
    }

    private func row(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// A picture that is hard to squeeze but cheap to make: a gradient with
    /// light, repeatable noise.
    private func noisyImage(width: Int, height: Int) -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1664525 &+ 1013904223
                let noise = Int(seed >> 24) % 48
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, (x * 255 / width) + noise))
                bytes[i + 1] = UInt8(min(255, (y * 255 / height) + noise))
                bytes[i + 2] = UInt8(min(255, 128 + noise))
            }
        }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    // MARK: What is sent

    @Test("the row has exactly the columns the table allows, and none from the library")
    func columnsAreExactlyTheAllowedOnes() {
        let expected: Set<String> = ["id", "type", "rating", "message", "anonymous", "name", "email", "screen", "app_version",
                                     "build", "platform", "os_version", "device_model", "ai_mode", "install_id", "screenshot_path"]
        #expect(FeedbackPayload.columnNames == expected)
        for banned in ["note", "card", "question", "answer", "deck", "course", "key", "token", "text", "front", "back"] {
            #expect(!FeedbackPayload.columnNames.contains { $0.contains(banned) }, "\(banned)")
        }
    }

    @Test("what the payload is built from carries no library field, and nothing reads the library or key storage")
    func sourceNeverTouchesTheLibrary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/GRASP/Shared/Feedback")
        let forbidden = ["AppStore", "GRASPDatabase", "database.", "TestQuestion", "AIKeyStore", "Keychain", "SecItem",
                         "import GRASPCore", "import GRDB", "CardActions", "QuestionBank", ": Course", "[Course]", ": Deck", "[Deck]", ": Card", "[Card]"]
        // The model and the service are the whole of what leaves the device.
        for name in ["FeedbackModel.swift", "FeedbackService.swift"] {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for token in forbidden { #expect(!text.contains(token), "\(name) mentions \(token)") }
        }
    }

    @Test("the facts that travel are exactly the seven in 'What gets sent'")
    func disclosureRows() {
        #expect(context.disclosure.map(\.label) == ["App version", "Platform", "OS version", "Device",
                                                    "Screen you were on", "AI", "Install ID"])
        #expect(context.disclosure.first?.value == "0.1.0 (build 1)")
    }

    @Test("anonymous drops the name and email, even when they were typed")
    func anonymousOn() {
        var d = draft()
        d.name = "Sam"; d.email = "sam@example.com"
        d.anonymous = true
        let payload = FeedbackPayloadBuilder.make(draft: d, context: context)
        #expect(payload.anonymous)
        #expect(payload.name == nil && payload.email == nil)
        let json = row(try! JSONEncoder().encode(payload))
        #expect(json["name"] == nil && json["email"] == nil)
    }

    @Test("with anonymous off, a name and email are sent, trimmed, and optional")
    func anonymousOff() {
        var d = draft()
        d.anonymous = false
        d.name = "  Sam  "; d.email = " sam@example.com "
        var payload = FeedbackPayloadBuilder.make(draft: d, context: context)
        #expect(payload.name == "Sam" && payload.email == "sam@example.com" && !payload.anonymous)
        d.name = ""; d.email = ""
        payload = FeedbackPayloadBuilder.make(draft: d, context: context)
        #expect(payload.name == nil && payload.email == nil)
        #expect(d.problem == nil)   // never required
    }

    @Test("the payload carries the context, the type and the rating, and a lowercase uuid id")
    func payloadFields() {
        var d = draft()
        d.rating = 4
        let payload = FeedbackPayloadBuilder.make(draft: d, context: context)
        #expect(payload.type == "confusing" && payload.rating == 4)
        #expect(payload.screen == "Deck > Questions" && payload.platform == "mac" && payload.aiMode == "cloud")
        #expect(payload.installId == "install-1" && payload.appVersion == "0.1.0" && payload.build == "1")
        #expect(payload.id == payload.id.lowercased() && UUID(uuidString: payload.id) != nil)
        #expect(payload.screenshotPath == nil)
    }

    // MARK: Validation and caps

    @Test("a message needs a kind and some words, and stops at 4000 characters")
    func messageRules() {
        var d = FeedbackDraft()
        #expect(d.problem != nil)
        d.type = .bug
        #expect(d.problem != nil)             // no message
        d.message = "   \n "
        #expect(d.problem != nil)             // only spaces
        d.message = "It crashed."
        #expect(d.problem == nil)
        d.message = String(repeating: "a", count: FeedbackLimits.messageMax)
        #expect(d.problem == nil)
        d.message = String(repeating: "a", count: FeedbackLimits.messageMax + 1)
        #expect(d.problem != nil)
    }

    @Test("a rating outside 1 to 5 is dropped, and a bad email is refused only when given")
    func ratingAndEmail() {
        var d = draft()
        d.rating = 9
        #expect(FeedbackPayloadBuilder.make(draft: d, context: context).rating == nil)
        #expect(d.problem != nil)             // the sheet only offers 1 to 5; anything else is refused
        d.rating = nil
        d.anonymous = false
        d.email = "not an email"
        #expect(d.problem != nil)
        d.email = "a@b.co"
        #expect(d.problem == nil)
    }

    @Test("a screenshot is scaled to 1600 px and under 500 KB, as a JPEG")
    func screenshotCaps() throws {
        let big = noisyImage(width: 2400, height: 1500)
        let prepared = try #require(FeedbackImage.prepare(big))
        #expect(prepared.count <= FeedbackLimits.screenshotMaxBytes)
        #expect(Array(prepared.prefix(2)) == [0xFF, 0xD8])
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(w, h) <= FeedbackLimits.screenshotLongEdge)
        #expect(FeedbackImage.prepare(Data("not an image".utf8)) == nil)
    }

    // MARK: Sending

    @Test("a send goes out once, with its screenshot named after its id")
    func sendsWithScreenshot() async throws {
        let (service, transport, queue, _) = makeService()
        var d = draft()
        d.screenshot = Data([0xFF, 0xD8, 1, 2, 3])
        #expect(await service.send(draft: d, context: context) == .sent)
        #expect(transport.rows.count == 1)
        let sent = row(transport.rows[0])
        let id = try #require(sent["id"] as? String)
        #expect(sent["screenshot_path"] as? String == "\(id).jpg")
        #expect(transport.uploads.map(\.path) == ["\(id).jpg"])
        #expect(queue.entries().isEmpty)
    }

    @Test("without a screenshot nothing is uploaded, and none is ever attached on its own")
    func noScreenshotByDefault() async {
        let (service, transport, _, _) = makeService()
        _ = await service.send(draft: draft(), context: context)
        #expect(transport.uploads.isEmpty)
        #expect(row(transport.rows[0])["screenshot_path"] == nil)
    }

    @Test("an invalid draft sends nothing")
    func invalidSendsNothing() async {
        let (service, transport, queue, _) = makeService()
        var d = draft("")
        #expect(await service.send(draft: d, context: context) == .invalid("Write a message first."))
        d = FeedbackDraft()
        _ = await service.send(draft: d, context: context)
        #expect(transport.rows.isEmpty && transport.uploads.isEmpty && queue.entries().isEmpty)
        #expect(service.sendsToday == 0)
    }

    @Test("Cancel only closes the sheet: it never calls the service")
    func cancelOnlyDismisses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/GRASP/Shared/Feedback/SendFeedbackSheet.swift"), encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.contains("Button(\"Cancel\")") })
        #expect(line.contains("{ dismiss() }"))
    }

    @Test("offline: the message is kept, and sends once, when the connection comes back")
    func queueAndRetry() async {
        let (service, transport, queue, _) = makeService(StubFeedbackTransport(mode: .offline))
        var d = draft()
        d.screenshot = Data([0xFF, 0xD8, 9])
        let outcome = await service.send(draft: d, context: context)
        guard case .queued(let offline, _) = outcome else { Issue.record("expected queued"); return }
        #expect(offline)
        #expect(queue.entries().count == 1 && service.queuedCount == 1)
        #expect(transport.rows.isEmpty)
        // Still offline: still there.
        await service.flushQueue()
        #expect(queue.entries().count == 1)
        // Back online.
        transport.mode = .ok
        await service.flushQueue()
        #expect(queue.entries().isEmpty && service.queuedCount == 0)
        #expect(transport.rows.count == 1 && transport.uploads.count == 1)
        // A second flush sends nothing again.
        await service.flushQueue()
        #expect(transport.rows.count == 1)
    }

    @Test("a server that says no keeps the text and says so in plain words")
    func rejectedIsKept() async {
        let (service, transport, queue, _) = makeService(StubFeedbackTransport(mode: .reject(403)))
        let outcome = await service.send(draft: draft(), context: context)
        guard case .queued(let offline, let message) = outcome else { Issue.record("expected queued"); return }
        #expect(!offline)
        #expect(message.hasPrefix("Couldn't send your feedback"))
        #expect(!message.contains("Error Domain"))
        #expect(queue.entries().count == 1)
        transport.mode = .ok
        await service.flushQueue()
        #expect(queue.entries().isEmpty && transport.rows.count == 1)
    }

    @Test("waiting messages are loaded when the app starts")
    func queueSurvivesRestart() async {
        let queue = MemoryFeedbackQueue()
        let (first, _, _, _) = makeService(StubFeedbackTransport(mode: .offline), queue: queue)
        _ = await first.send(draft: draft(), context: context)
        let (second, transport, _, _) = makeService(queue: queue)
        #expect(second.queuedCount == 1)
        await second.flushQueue()
        #expect(transport.rows.count == 1 && second.queuedCount == 0)
    }

    @Test("with no server set up it says so and keeps nothing")
    func notConfigured() async {
        let service = FeedbackService(transport: nil, queue: MemoryFeedbackQueue(), defaults: defaults())
        #expect(await service.send(draft: draft(), context: context) == .notConfigured)
        #expect(service.sendsToday == 0)
    }

    // MARK: Limits

    @Test("five sends a day, then a plain message, then a fresh day")
    func rateLimit() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, transport, _, _) = makeService(now: { clock })
        for i in 0..<FeedbackLimits.sendsPerDay {
            #expect(await service.send(draft: draft("Message \(i)"), context: context) == .sent)
        }
        #expect(service.rateLimitReached)
        #expect(await service.send(draft: draft("One more"), context: context) == .rateLimited)
        #expect(transport.rows.count == 5)
        #expect(FeedbackService.rateLimitMessage.contains("try again tomorrow"))
        clock = clock.addingTimeInterval(24 * 60 * 60)
        #expect(!service.rateLimitReached)
        #expect(await service.send(draft: draft("Next day"), context: context) == .sent)
    }

    @Test("a send that was only saved still counts toward the day")
    func queuedCountsToo() async {
        let (service, _, _, _) = makeService(StubFeedbackTransport(mode: .offline))
        _ = await service.send(draft: draft(), context: context)
        #expect(service.sendsToday == 1)
    }

    @Test("the install id is random, made once, and kept")
    func installId() {
        let d = defaults()
        let a = FeedbackService(transport: nil, queue: MemoryFeedbackQueue(), defaults: d)
        let first = a.installId
        #expect(UUID(uuidString: first) != nil)
        #expect(FeedbackService(transport: nil, queue: MemoryFeedbackQueue(), defaults: d).installId == first)
        #expect(FeedbackService(transport: nil, queue: MemoryFeedbackQueue(), defaults: defaults()).installId != first)
    }

    // MARK: The real transport's requests

    private func realTransport(status: Int) -> SupabaseFeedbackTransport {
        StubURLProtocol.status = status
        StubURLProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var transport = SupabaseFeedbackTransport(configuration: SyncConfiguration(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key"))!
        transport.session = URLSession(configuration: configuration)
        return transport
    }

    @Test("a row is posted to the feedback table with only the public key, asking for nothing back")
    func insertRequest() async throws {
        let transport = realTransport(status: 201)
        try await transport.insert(row: Data("{}".utf8))
        let request = try #require(StubURLProtocol.seen.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/feedback")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "return=minimal")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("a picture goes to the private bucket as a JPEG, never overwriting")
    func uploadRequest() async throws {
        let transport = realTransport(status: 200)
        try await transport.upload(screenshot: Data([0xFF, 0xD8]), path: "abc.jpg")
        let request = try #require(StubURLProtocol.seen.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/storage/v1/object/feedback-screenshots/abc.jpg")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(request.value(forHTTPHeaderField: "x-upsert") == "false")
    }

    @Test("a repeat of the same id counts as sent; a busy server is retried; a refusal is kept")
    func statusHandling() async {
        let duplicate = realTransport(status: 409)
        await #expect(throws: Never.self) { try await duplicate.insert(row: Data("{}".utf8)) }
        let busy = realTransport(status: 503)
        await #expect(throws: FeedbackError.temporary(status: 503)) { try await busy.insert(row: Data("{}".utf8)) }
        let refused = realTransport(status: 401)
        await #expect(throws: FeedbackError.rejected(status: 401)) { try await refused.insert(row: Data("{}".utf8)) }
    }

    // MARK: The soft asks

    private func asks(_ d: UserDefaults, clock: @escaping () -> Date) -> FeedbackAsks { FeedbackAsks(defaults: d, now: clock) }

    @Test("nothing is asked on a brand-new install")
    func noAskAtFirst() {
        let a = asks(defaults(), clock: { Date() })
        a.recordLaunch(libraryHasData: false)
        #expect(a.due(busy: false, sheetShowing: false) == nil)
    }

    @Test("after the first finished test, one ask, once ever")
    func firstTestAsk() {
        let a = asks(defaults(), clock: { Date() })
        a.recordLaunch(libraryHasData: false)
        a.noteTestFinished()
        #expect(a.showIfDue(busy: false, sheetShowing: false) == .firstTest)
        a.dismiss()
        #expect(a.showIfDue(busy: false, sheetShowing: false) == nil)   // never again
        a.noteTestFinished()                                              // a second test changes nothing
        #expect(a.due(busy: false, sheetShowing: false) == nil)
    }

    @Test("seven days after first launch, one ask, once ever, and not before")
    func weekAsk() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let a = asks(defaults(), clock: { clock })
        a.recordLaunch(libraryHasData: false)
        clock = clock.addingTimeInterval(6 * 24 * 60 * 60 + 23 * 60 * 60)
        #expect(a.due(busy: false, sheetShowing: false) == nil)
        clock = clock.addingTimeInterval(2 * 60 * 60)
        #expect(a.showIfDue(busy: false, sheetShowing: false) == .week)
        a.dismiss()
        #expect(a.due(busy: false, sheetShowing: false) == nil)
    }

    @Test("never during Study, Learn or a Test, and never over a sheet; it waits instead")
    func notWhileBusy() {
        let a = asks(defaults(), clock: { Date() })
        a.recordLaunch(libraryHasData: false)
        a.noteTestFinished()
        #expect(a.showIfDue(busy: true, sheetShowing: false) == nil)
        #expect(a.showIfDue(busy: false, sheetShowing: true) == nil)
        #expect(a.showing == nil)
        // It was not used up by waiting.
        #expect(a.showIfDue(busy: false, sheetShowing: false) == .firstTest)
    }

    @Test("a first-test ask closes with any choice, and the week ask still comes later")
    func eachAskIsItsOwn() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let a = asks(defaults(), clock: { clock })
        a.recordLaunch(libraryHasData: false)
        a.noteTestFinished()
        #expect(a.showIfDue(busy: false, sheetShowing: false) == .firstTest)
        #expect(a.showIfDue(busy: false, sheetShowing: false) == nil)    // one at a time
        a.dismiss()
        clock = clock.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(a.showIfDue(busy: false, sheetShowing: false) == .week)
    }

    @Test("Don't ask again ends both asks for good")
    func dontAskAgain() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let d = defaults()
        let a = asks(d, clock: { clock })
        a.recordLaunch(libraryHasData: false)
        a.noteTestFinished()
        _ = a.showIfDue(busy: false, sheetShowing: false)
        a.neverAskAgain()
        clock = clock.addingTimeInterval(30 * 24 * 60 * 60)
        #expect(a.due(busy: false, sheetShowing: false) == nil)
        #expect(asks(d, clock: { clock }).due(busy: false, sheetShowing: false) == nil)   // after a relaunch too
    }

    @Test("a library that already has courses or cards at first launch is never asked")
    func existingLibraryIsMe() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let d = defaults()
        let a = asks(d, clock: { clock })
        a.recordLaunch(libraryHasData: true)
        a.noteTestFinished()
        clock = clock.addingTimeInterval(30 * 24 * 60 * 60)
        #expect(a.due(busy: false, sheetShowing: false) == nil)
        // Only the first launch decides: content added later changes nothing.
        let later = asks(d, clock: { clock })
        later.recordLaunch(libraryHasData: false)
        #expect(later.due(busy: false, sheetShowing: false) == nil)
    }

    @Test("the first launch is recorded once")
    func firstLaunchOnce() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let d = defaults()
        let a = asks(d, clock: { clock })
        a.recordLaunch(libraryHasData: false)
        clock = clock.addingTimeInterval(3 * 24 * 60 * 60)
        a.recordLaunch(libraryHasData: false)
        #expect(d.object(forKey: FeedbackAsks.firstLaunchKey) as? Date == Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: Copy

    @Test("no feedback text uses a double hyphen or a dash")
    func copy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/GRASP/Shared/Feedback")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in text.matches(of: /"[^"\n]*"/).map({ String($0.output) }) {
                #expect(!literal.contains(" -- ") && !literal.contains("\u{2014}") && !literal.contains("\u{2013}"), "\(file.lastPathComponent): \(literal)")
            }
        }
        #expect(FeedbackAsk.firstTest.message.contains("?") && FeedbackAsk.week.message.contains("?"))
    }

    @Test("the screens it can name are a fixed list of plain words")
    func screensAreFixed() {
        let values = ["Home", "Calendar", "Study guides", "Library", "Course", "Deck > Cards", "Deck > Overview",
                      "Deck > Questions", "Study", "Learn", "Test", "Today", "Courses", "Settings", "Search"]
        for value in values { #expect(FeedbackScreen(rawValue: value) != nil, "\(value)") }
    }
}
