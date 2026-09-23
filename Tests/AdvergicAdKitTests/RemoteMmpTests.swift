import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class RemoteMmpTests: XCTestCase {

    private func parse(_ text: String) -> [RemoteMmp] { RemoteMmp.parseAll(parseJSON(text)) }

    func testParsesTheMiddlewaresConnectedMmpBlock() {
        let mmps = parse(#"{"connectedMmp":{"mmpId":"appsflyer","credentials":{"dev_key":"dk"},"formats":["banner"]}}"#)
        XCTAssertEqual(mmps, [RemoteMmp(id: "appsflyer", credentials: ["dev_key": "dk"], formats: ["banner"])])
    }

    func testParsesASingularBlock() {
        let mmp = parse(#"{"connectedMmp":{"mmpId":"singular","credentials":{"api_key":"k","secret":"s"}}}"#)[0]
        XCTAssertEqual(mmp.credential("api_key"), "k")
        XCTAssertEqual(mmp.credential("secret"), "s")
    }

    func testNoMmpConnectedParsesToEmpty() {
        XCTAssertTrue(parse(#"{"mediation":{}}"#).isEmpty)
    }

    func testAnEntryWithoutAnIdIsIgnored() {
        XCTAssertTrue(parse(#"{"connectedMmp":{"credentials":{"dev_key":"dk"}}}"#).isEmpty)
    }

    func testTheIdIsMatchedCaseInsensitively() {
        XCTAssertEqual(parse(#"{"connectedMmp":{"mmpId":" AppsFlyer "}}"#).first?.id, "appsflyer")
    }

    func testAnEmptyFormatListMeansEveryFormat() {
        let mmp = parse(#"{"connectedMmp":{"mmpId":"adjust","formats":[]}}"#)[0]
        XCTAssertTrue(mmp.reports(format: "banner"))
        XCTAssertTrue(mmp.reports(format: "app_open"))
    }

    func testAFormatListIsHonouredExactly() {
        let mmp = parse(#"{"connectedMmp":{"mmpId":"adjust","formats":["Rewarded"]}}"#)[0]
        XCTAssertTrue(mmp.reports(format: "rewarded"))
        XCTAssertFalse(mmp.reports(format: "banner"))
    }

    func testABlankCredentialIsTreatedAsAbsent() {
        XCTAssertNil(parse(#"{"connectedMmp":{"mmpId":"adjust","credentials":{"app_token":"  "}}}"#)[0].credential("app_token"))
    }

    func testAMalformedBlockDoesNotThrow() {
        XCTAssertTrue(parse(#"{"connectedMmp":"nope","connectedMmps":7}"#).isEmpty)
        XCTAssertEqual(parse(#"{"connectedMmps":[1,"x",{"mmpId":"adjust","formats":"all"}]}"#).map(\.id), ["adjust"])
    }

    func testParsesAnAdjustBlock() {
        let mmp = parse(#"{"connectedMmp":{"mmpId":"adjust","credentials":{"app_token":"t","environment":"sandbox"}}}"#)[0]
        XCTAssertEqual(mmp.credential("environment"), "sandbox")
    }

    func testParsesAFirebaseBlockWithNoCredentials() {
        let mmp = parse(#"{"connectedMmps":[{"mmpId":"firebase","credentials":{},"formats":[]}]}"#)[0]
        XCTAssertEqual(mmp.id, "firebase")
        XCTAssertTrue(mmp.credentials.isEmpty)
    }

    func testParsesSeveralConnectedMmpsInConfigOrder() {
        XCTAssertEqual(parse(#"{"connectedMmps":[{"mmpId":"adjust"},{"mmpId":"firebase"}]}"#).map(\.id), ["adjust", "firebase"])
    }

    func testTheSameMmpListedTwiceIsOnlyReportedToOnce() {
        let mmps = parse(#"{"connectedMmps":[{"mmpId":"adjust","credentials":{"app_token":"first"}},{"mmpId":"ADJUST","credentials":{"app_token":"second"}}]}"#)
        XCTAssertEqual(mmps.count, 1)
        XCTAssertEqual(mmps[0].credential("app_token"), "first")
    }

    func testAnArrayWinsOverTheLegacySingleObject() {
        XCTAssertEqual(parse(#"{"connectedMmps":[{"mmpId":"adjust"}],"connectedMmp":{"mmpId":"appsflyer"}}"#).map(\.id), ["adjust"])
    }

    func testAnUnintegratedMmpIsIgnored() {
        let reporter = MmpFactory.create([RemoteMmp(id: "branch", credentials: [:], formats: [])])
        XCTAssertTrue(reporter is NoMmpReporter)
    }

    func testAMissingModuleIsIgnoredRatherThanFatal() {
        // No AppsFlyer module is linked into the test bundle.
        let reporter = MmpFactory.create([RemoteMmp(id: "appsflyer", credentials: [:], formats: [])])
        XCTAssertTrue(reporter is NoMmpReporter)
    }
}
