import Testing
@testable import GRASPCore

@Suite("TextCleaning")
struct TextCleaningTests {
    @Test("strips a base64 data URI image before anything else touches it")
    func stripsBase64Image() {
        let huge = String(repeating: "A", count: 5000)
        let text = "before ![](data:image/jpeg;base64,\(huge)) after"
        let cleaned = TextCleaning.stripBase64Images(text)
        #expect(cleaned == "before [image] after")
        #expect(cleaned.count < 100)
    }

    @Test("recognizes the empty-stub marker")
    func recognizesEmptyStub() {
        #expect(TextCleaning.isEmptyStub("*No notes or outline available for this entry.*"))
        #expect(!TextCleaning.isEmptyStub("Groundwater represents the largest reservoir of freshwater."))
    }

    @Test("extracts and removes a date line")
    func extractsDateLine() {
        let body = "*Date: October 28, 2025*\n\nSome real content here."
        let (date, cleaned) = TextCleaning.extractDateLine(body)
        #expect(date != nil)
        #expect(!cleaned.contains("*Date:"))
        #expect(cleaned.contains("Some real content"))
    }
}
