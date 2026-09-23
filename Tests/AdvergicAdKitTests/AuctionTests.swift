import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

private final class StubBidProvider: AdvergicMetaBidProvider {
    var price = 1.25
    var fail = false
    var delay: TimeInterval = 0
    private(set) var calls = 0

    func fetchMetaBid(placementId: String, bidderToken: String, size: AdvergicAdSize) async throws -> AdvergicMetaBid {
        calls += 1
        if delay > 0 { Thread.sleep(forTimeInterval: delay) } // deliberately ignores cancellation
        if fail { throw URLError(.cannotConnectToHost) }
        return AdvergicMetaBid(payload: "adm", price: price)
    }
}

final class AuctionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AdPriceHistory.reset(clearStore: false)
        AdPriceHistory.attach(defaults: UserDefaults(suiteName: "advergic.tests.\(UUID().uuidString)")!)
    }

    override func tearDown() {
        AdPriceHistory.reset()
        super.tearDown()
    }

    private func demand(_ network: AdvergicAdNetwork, floor: Double?) -> RemoteDemand {
        RemoteDemand(network: network, adUnitId: "\(network.name.lowercased())_unit", label: network.name.lowercased(),
                     floor: floor, enabled: true)
    }

    private let token: AdAuction.TokenSource = { _ in "token" }

    func testWithoutBiddersEntriesRankOnTheirFloors() async {
        let ranked = await AdAuction.resolve(
            entries: [demand(.yandex, floor: 0.4), demand(.admobTest, floor: 0.5), demand(.pangle, floor: nil)],
            size: .banner, placement: "p", bidProvider: nil, tokenSource: token
        )
        XCTAssertEqual(ranked.map(\.demand.network), [.admobTest, .yandex, .pangle])
        XCTAssertEqual(ranked.last?.price, 0)
        XCTAssertEqual(ranked[0].describe(), "[floor $0.5000]")
    }

    func testARealBidOutranksFloorsAndCarriesItsPayload() async {
        let provider = StubBidProvider()
        let ranked = await AdAuction.resolve(
            entries: [demand(.admobTest, floor: 0.5), demand(.meta, floor: nil)],
            size: .banner, placement: "p", bidProvider: provider, tokenSource: token
        )
        XCTAssertEqual(ranked[0].demand.network, .meta)
        XCTAssertTrue(ranked[0].isRealBid)
        XCTAssertEqual(ranked[0].bid?.payload, "adm")
        XCTAssertEqual(ranked[0].describe(), "[BID $1.2500 USD]")
    }

    func testABidUnderItsFloorIsRejectedNotRanked() async {
        let provider = StubBidProvider()
        provider.price = 0.1
        let ranked = await AdAuction.resolve(entries: [demand(.meta, floor: 0.3)], size: .banner, placement: "p",
                                             bidProvider: provider, tokenSource: token)
        XCTAssertFalse(ranked[0].isRealBid)
        XCTAssertEqual(ranked[0].price, 0.3)
    }

    func testAFailedBidFallsBackToTheEstimate() async {
        let provider = StubBidProvider()
        provider.fail = true
        let ranked = await AdAuction.resolve(entries: [demand(.meta, floor: 0.2)], size: .banner, placement: "p",
                                             bidProvider: provider, tokenSource: token)
        XCTAssertFalse(ranked[0].isRealBid)
        XCTAssertEqual(ranked[0].price, 0.2)
    }

    func testNoBidderTokenMeansNoBidRequest() async {
        let provider = StubBidProvider()
        _ = await AdAuction.resolve(entries: [demand(.meta, floor: 0.2)], size: .banner, placement: "p",
                                    bidProvider: provider, tokenSource: { _ in nil })
        XCTAssertEqual(provider.calls, 0)
    }

    func testASlowBidderThatIgnoresCancellationCannotHoldTheSlotPastTheTimeout() async {
        let provider = StubBidProvider()
        provider.delay = AdAuction.timeout + 2
        let started = Date()
        let ranked = await AdAuction.resolve(entries: [demand(.meta, floor: 0.2)], size: .banner, placement: "p",
                                             bidProvider: provider, tokenSource: token)
        XCTAssertLessThan(Date().timeIntervalSince(started), AdAuction.timeout + 1)
        XCTAssertFalse(ranked[0].isRealBid)
    }

    func testAnObservedPriceOutranksTheConfiguredFloor() async {
        AdPriceHistory.record(network: .inMobi, placement: "p", price: 1.4)
        let ranked = await AdAuction.resolve(entries: [demand(.admobTest, floor: 0.5), demand(.inMobi, floor: 0.2)],
                                             size: .banner, placement: "p", bidProvider: nil, tokenSource: token)
        XCTAssertEqual(ranked[0].demand.network, .inMobi)
        XCTAssertTrue(ranked[0].isLearned)
        XCTAssertEqual(ranked[0].describe(), "[observed $1.4000]")
    }

    func testEqualPricesKeepPublishedOrder() async {
        let ranked = await AdAuction.resolve(
            entries: [demand(.yandex, floor: 0.4), demand(.pangle, floor: 0.4), demand(.liftoff, floor: 0.4)],
            size: nil, placement: "p", bidProvider: nil, tokenSource: token
        )
        XCTAssertEqual(ranked.map(\.demand.network), [.yandex, .pangle, .liftoff])
    }

    // MARK: Price history

    func testTheHistoryIsAnExponentialMovingAverage() {
        AdPriceHistory.record(network: .admobTest, placement: "p", price: 1.0)
        AdPriceHistory.record(network: .admobTest, placement: "p", price: 2.0)
        XCTAssertEqual(AdPriceHistory.observed(network: .admobTest, placement: "p")!, 1.3, accuracy: 1e-9)
    }

    func testAZeroPriceIsNotLearned() {
        AdPriceHistory.record(network: .admobTest, placement: "p", price: 0)
        XCTAssertNil(AdPriceHistory.observed(network: .admobTest, placement: "p"))
    }

    func testPricesArePerPlacement() {
        AdPriceHistory.record(network: .admobTest, placement: "a", price: 1)
        XCTAssertNil(AdPriceHistory.observed(network: .admobTest, placement: "b"))
    }

    func testTheHistorySurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "advergic.tests.\(UUID().uuidString)")!
        AdPriceHistory.reset(clearStore: false)
        AdPriceHistory.attach(defaults: defaults)
        AdPriceHistory.record(network: .yandex, placement: "p", price: 0.8)
        AdPriceHistory.reset(clearStore: false)
        AdPriceHistory.attach(defaults: defaults)
        XCTAssertEqual(AdPriceHistory.observed(network: .yandex, placement: "p"), 0.8)
    }

    // MARK: Chain

    func testTheChainWalksRungsInOrderAndNamesEveryOneWhenExhausted() {
        let chain = AdChain(placementName: "banner_320x50", rungs: [
            ResolvedDemand(demand: demand(.meta, floor: nil), price: 2, isRealBid: true),
            ResolvedDemand(demand: demand(.admobTest, floor: 0.5), price: 0.5, isRealBid: false),
        ], request: "banner 320x50")
        XCTAssertEqual(chain.next()?.demand.network, .meta)
        XCTAssertEqual(chain.position(), 1)
        XCTAssertEqual(chain.next()?.demand.network, .admobTest)
        XCTAssertNil(chain.next())
        XCTAssertEqual(chain.exhaustedMessage(lastError: "ADMOB_TEST: No fill"),
                       "no fill for banner_320x50 after 2 tier(s): META:meta, ADMOB_TEST:admob_test. Last error: ADMOB_TEST: No fill")
    }

    func testAnEmptyChainSaysNoDemand() {
        XCTAssertEqual(AdChain(placementName: "x", rungs: []).exhaustedMessage(lastError: nil),
                       "no demand configured for x")
    }
}
