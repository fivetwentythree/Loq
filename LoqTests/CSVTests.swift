import XCTest
@testable import Loq

final class CSVTests: XCTestCase {
    func testQuotesCommasNewlinesAndQuotesWithoutLosingLabelText() {
        XCTAssertEqual(CSV.cell("yes,no"), "\"yes,no\"")
        XCTAssertEqual(CSV.cell("say \"yes\"\nagain"), "\"say \"\"yes\"\"\nagain\"")
        XCTAssertEqual(CSV.cell("stop"), "stop")
    }

    func testNeutralizesFormulasIncludingLeadingWhitespace() {
        XCTAssertEqual(CSV.cell("=1+1"), "'=1+1")
        XCTAssertEqual(CSV.cell("  @SUM(1)"), "'  @SUM(1)")
        XCTAssertEqual(CSV.cell("\t-1"), "'\t-1")
        XCTAssertEqual(CSV.cell("+yes"), "'+yes")
    }
}
