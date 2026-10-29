import Testing
import Foundation
import GRDB
@testable import GRASP
import GRASPCore

@Suite("First-run tutorial")
@MainActor
struct TutorialTests {
    /// A flow with its own throwaway defaults, so no test sees another's flag.
    private func makeFlow(platform: TutorialPlatform = .mac) -> (TutorialFlow, UserDefaults) {
        let name = "tutorial-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (TutorialFlow(seen: TutorialSeenStore(defaults: defaults), platform: platform), defaults)
    }

    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// Pretends the deck page is on screen, so the deck steps have controls to point at.
    private func showDeckPage(_ flow: TutorialFlow) {
        flow.setViewport(window)
        for (i, target) in TutorialTarget.allCases.enumerated() {
            flow.setFrame(CGRect(x: 100, y: 80 + i * 50, width: 120, height: 32), for: target)
        }
    }

    // MARK: Whether it runs

    @Test("a first-time user (nothing seen, an empty library) gets the tutorial")
    func newUser() {
        let (flow, _) = makeFlow()
        flow.launchIfFirstTime(libraryHasData: false, linkedToAccount: false)
        #expect(flow.isActive)
        #expect(flow.index == 0)
        #expect(TutorialFlow.shouldRunAutomatically(seen: false, libraryHasData: false, linkedToAccount: false))
    }

    @Test("an existing user never gets it on their own, and is marked as having seen it")
    func existingUser() {
        let (flow, defaults) = makeFlow()
        flow.launchIfFirstTime(libraryHasData: true, linkedToAccount: false)
        #expect(!flow.isActive)
        #expect(defaults.bool(forKey: TutorialSeenStore.key))
        #expect(!TutorialFlow.shouldRunAutomatically(seen: false, libraryHasData: true, linkedToAccount: false))
    }

    @Test("someone who has seen it is not shown it again")
    func alreadySeen() {
        let (flow, defaults) = makeFlow()
        defaults.set(true, forKey: TutorialSeenStore.key)
        flow.launchIfFirstTime(libraryHasData: false, linkedToAccount: false)
        #expect(!flow.isActive)
    }

    @Test("a profile signed in to an account is left alone, and not marked seen, until its library arrives")
    func linkedAccount() {
        let (flow, defaults) = makeFlow()
        flow.launchIfFirstTime(libraryHasData: false, linkedToAccount: true)
        #expect(!flow.isActive)
        #expect(!defaults.bool(forKey: TutorialSeenStore.key))
    }

    // MARK: Ending it

    @Test("skipping at every step marks it seen and closes it")
    func skipAtEveryStep() {
        let (probe, _) = makeFlow()
        for step in 0..<probe.steps.count {
            let (flow, defaults) = makeFlow()
            flow.start(at: step)
            flow.skip()
            #expect(!flow.isActive, "step \(step + 1)")
            #expect(defaults.bool(forKey: TutorialSeenStore.key), "step \(step + 1)")
        }
    }

    @Test("finishing marks it seen")
    func finishing() {
        let (flow, defaults) = makeFlow()
        flow.start()
        for _ in 0..<flow.steps.count { flow.next() }
        #expect(!flow.isActive)
        #expect(defaults.bool(forKey: TutorialSeenStore.key))
    }

    @Test("closing the app mid-tour does not count: the next launch starts again from the top")
    func closedMidTour() {
        let (flow, defaults) = makeFlow()
        flow.launchIfFirstTime(libraryHasData: false, linkedToAccount: false)
        flow.next(); flow.next()
        #expect(flow.index == 2)
        #expect(!defaults.bool(forKey: TutorialSeenStore.key))
        // A new launch: a fresh flow over the same saved flag.
        let relaunched = TutorialFlow(seen: TutorialSeenStore(defaults: defaults), platform: .mac)
        relaunched.launchIfFirstTime(libraryHasData: false, linkedToAccount: false)
        #expect(relaunched.isActive)
        #expect(relaunched.index == 0)
    }

    @Test("replay works after it has been seen, with or without courses")
    func replay() {
        let (flow, defaults) = makeFlow()
        defaults.set(true, forKey: TutorialSeenStore.key)
        flow.start()
        #expect(flow.isActive)
        #expect(flow.index == 0)
    }

    // MARK: Moving through it

    @Test("eight steps in the planned order, each counted out of eight")
    func steps() {
        let (flow, _) = makeFlow()
        #expect(flow.steps.map(\.id) == ["welcome", "courses", "notes", "tabs", "modes", "add", "ai", "done"])
        flow.start(at: 2)
        #expect(flow.progressLabel == "Step 3 of 8")
    }

    @Test("Back and Next move one step; Back is not offered on the first")
    func backAndNext() {
        let (flow, _) = makeFlow()
        flow.start()
        flow.back()
        #expect(flow.index == 0)
        flow.next()
        flow.next()
        #expect(flow.index == 2)
        flow.back()
        #expect(flow.index == 1)
    }

    @Test("the tabs step advances only on the intended taps, in order")
    func tabsStepWaitsForRealTaps() {
        let (flow, _) = makeFlow()
        showDeckPage(flow)
        flow.start(at: 3)
        #expect(flow.isWaiting)
        #expect(flow.waitPrompt == "Tap Cards.")
        flow.next()                                   // Next is not available while waiting
        #expect(flow.index == 3)
        flow.didTap(.deckTab("Questions"))            // the wrong tap first
        #expect(flow.index == 3)
        flow.didTap(.deckTab("Overview"))
        #expect(flow.index == 3)
        flow.didTap(.deckTab("Cards"))
        #expect(flow.index == 3)
        #expect(flow.waitPrompt == "Now tap Questions.")
        flow.didTap(.deckTab("Questions"))
        #expect(flow.index == 4)                      // on to Study, Learn and Test
    }

    @Test("Back from a waiting step starts its taps over")
    func backResetsTaps() {
        let (flow, _) = makeFlow()
        showDeckPage(flow)
        flow.start(at: 3)
        flow.didTap(.deckTab("Cards"))
        flow.back()
        flow.next()
        #expect(flow.index == 3)
        #expect(flow.waitPrompt == "Tap Cards.")
    }

    @Test("taps do nothing while the tutorial is closed")
    func tapsIgnoredWhenClosed() {
        let (flow, _) = makeFlow()
        showDeckPage(flow)
        flow.didTap(.deckTab("Cards"))
        #expect(flow.index == 0)
        #expect(!flow.isActive)
    }

    // MARK: No deck page (a first-time user)

    @Test("with no deck page the tabs step is a plain card that does not wait")
    func emptyLibraryFallback() {
        let (flow, _) = makeFlow()
        flow.setViewport(window)                       // no deck controls on screen
        flow.start(at: 3)
        #expect(flow.spotlight == nil)
        #expect(flow.isFallback)
        #expect(!flow.isWaiting)
        flow.next()                                    // Next works straight away
        #expect(flow.index == 4)
        #expect(flow.current.fallbackNote == "Once you add a course you'll see this.")
    }

    @Test("a control that has scrolled off screen falls back to the plain card")
    func offScreenFallsBack() {
        let (flow, _) = makeFlow()
        flow.setViewport(window)
        flow.start(at: 3)
        flow.setFrame(CGRect(x: 100, y: 900, width: 120, height: 32), for: .deckTabs)
        #expect(flow.isFallback)
        flow.setFrame(CGRect(x: 100, y: 80, width: 120, height: 32), for: .deckTabs)
        #expect(!flow.isFallback)
        #expect(flow.spotlight != nil)
    }

    @Test("when a layout swaps one copy of a control for another, the old copy leaving keeps the new copy's frame")
    func oldCopyLeavingKeepsNewFrame() {
        let (flow, _) = makeFlow()
        flow.setViewport(window)
        flow.start(at: 4)
        let oldCopy = UUID(), newCopy = UUID()
        flow.setFrame(CGRect(x: 10, y: 100, width: 80, height: 30), for: .studyButton, owner: oldCopy)
        // A narrower window: the new copy reports first, then the old one goes away.
        flow.setFrame(CGRect(x: 20, y: 100, width: 40, height: 30), for: .studyButton, owner: newCopy)
        flow.clearFrame(for: .studyButton, owner: oldCopy)
        #expect(flow.spotlight == CGRect(x: 20, y: 100, width: 40, height: 30))
        flow.clearFrame(for: .studyButton, owner: newCopy)
        #expect(flow.spotlight == nil)
    }

    @Test("the three study buttons are lit together")
    func modesLitTogether() {
        let (flow, _) = makeFlow()
        flow.setViewport(window)
        flow.setFrame(CGRect(x: 10, y: 100, width: 80, height: 30), for: .studyButton)
        flow.setFrame(CGRect(x: 100, y: 100, width: 80, height: 30), for: .learnButton)
        flow.setFrame(CGRect(x: 190, y: 100, width: 80, height: 30), for: .testButton)
        flow.start(at: 4)
        #expect(flow.spotlight == CGRect(x: 10, y: 100, width: 260, height: 30))
    }

    // MARK: The coach card never covers what it is about

    @Test("the card never overlaps the lit control, on a Mac window and an iPhone SE")
    func cardAvoidsSpotlight() {
        let cases: [(CGSize, CGRect)] = [
            (CGSize(width: 776, height: 476), CGRect(x: 0, y: 48, width: 260, height: 420)),    // Mac sidebar
            (CGSize(width: 776, height: 476), CGRect(x: 520, y: 20, width: 250, height: 44)),   // deck tabs
            (CGSize(width: 351, height: 643), CGRect(x: 0, y: 580, width: 70, height: 56)),     // tab bar item
            (CGSize(width: 351, height: 643), CGRect(x: 0, y: 40, width: 351, height: 40)),     // iPhone tabs
            (CGSize(width: 351, height: 643), CGRect(x: 0, y: 90, width: 351, height: 44)),     // study buttons
        ]
        for (size, hole) in cases {
            let p = TutorialOverlay.Placement.make(hole: hole, in: size)
            let card = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
            #expect(!card.intersects(hole), "\(size) \(hole)")
            #expect(card.minX >= 0 && card.maxX <= size.width && card.minY >= 0 && card.maxY <= size.height, "\(size) \(hole)")
        }
    }

    // MARK: Copy

    @Test("no step uses a double hyphen or a dash, and only the AI step carries the sparkle line")
    func copy() {
        for platform in [TutorialPlatform.mac, .phone] {
            let (flow, _) = makeFlow(platform: platform)
            for step in flow.steps {
                let text = [step.title, step.body, step.aiLine ?? "", step.fallbackNote] + step.waitPrompts
                for line in text {
                    #expect(!line.contains(" -- ") && !line.contains("--") && !line.contains("\u{2014}") && !line.contains("\u{2013}"), "\(step.id): \(line)")
                }
                #expect((step.aiLine != nil) == (step.id == "ai"), Comment(rawValue: step.id))
            }
        }
    }

    // MARK: Nothing is written

    /// Every table, every row, as text.
    private func snapshot(_ store: AppStore) throws -> String {
        try store.database.queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            var out = ""
            for table in tables {
                // Some tables (the search index) have no rowid, so sort the text.
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"").map { String(describing: $0) }.sorted()
                out += "\(table):\(rows.joined(separator: "|"))\n"
            }
            return out
        }
    }

    @Test("a full run, and a skip at every step, leave the database exactly as it was")
    func databaseUnchanged() throws {
        // A real AppStore reads the AI key from the Keychain when it opens, and
        // that can raise a system password prompt that hangs the run. This flag
        // (debug only) makes it skip the Keychain entirely, and the count
        // proves it did.
        AIKeyStore.skipsKeychain = true
        let callsBefore = AIKeyStore.keychainCalls
        defer { #expect(AIKeyStore.keychainCalls == callsBefore) }
        let store = AppStore(profile: .preview)
        defer { store.preferences.removeObject(forKey: TutorialSeenStore.key) }
        let now = "2026-10-20 12:00:00.000"
        try store.database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO course(id,name,sortIndex,isArchived,createdAt,updatedAt) VALUES ('c1','Biology',0,0,'\(now)','\(now)');
                INSERT INTO deck(id,courseId,name,origin,sortIndex,createdAt,updatedAt) VALUES ('d1','c1','Cells','manual',0,'\(now)','\(now)');
                INSERT INTO card(id,front,back,origin,status,due,createdAt,updatedAt) VALUES ('k1','Q','A','manual','active','\(now)','\(now)','\(now)');
                INSERT INTO deckCard(deckId,cardId,sortIndex) VALUES ('d1','k1',0);
                """)
        }
        let before = try snapshot(store)
        let flow = store.tutorial

        // A full run, tapping the real tabs on the way.
        flow.setViewport(window)
        for (i, target) in TutorialTarget.allCases.enumerated() {
            flow.setFrame(CGRect(x: 100, y: 80 + i * 50, width: 120, height: 32), for: target)
        }
        store.preferences.removeObject(forKey: TutorialSeenStore.key)
        flow.start()
        for _ in 0..<(flow.steps.count + 2) {
            flow.didTap(.deckTab("Cards"))
            flow.didTap(.deckTab("Questions"))
            flow.next()
        }
        #expect(!flow.isActive)
        #expect(try snapshot(store) == before)

        // A skip at every step.
        for step in 0..<flow.steps.count {
            flow.start(at: step)
            flow.skip()
            #expect(try snapshot(store) == before, "skip at step \(step + 1)")
        }
        // The first-run check itself reads and writes nothing in the library.
        store.preferences.removeObject(forKey: TutorialSeenStore.key)
        store.startTutorialIfFirstTime()
        #expect(try snapshot(store) == before)
    }
}
