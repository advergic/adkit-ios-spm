import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class RemoteAdsConfigTests: XCTestCase {

    private func parse(_ text: String) -> RemoteAdsConfig { RemoteAdsConfig.parse(parseJSON(text)) }

    private let sample = """
    {
      "mediation": {
        "version": 5,
        "placements": [
          { "id": "p1", "name": "banner_320x50", "format": "banner", "size": {"width": 320, "height": 50},
            "bidding": [ {"network": "meta", "adUnitId": "m1", "label": "meta_banner", "floor": null} ],
            "waterfall": [
              {"network": "admob", "adUnitId": "a1", "label": "admob_banner", "floor": 0.5, "enabled": true},
              {"network": "yandex", "adUnitId": "y1", "label": "yandex_banner", "floor": 0.4},
              {"network": "pangle", "adUnitId": "p1", "label": "pangle_banner", "floor": 0.3, "enabled": false}
            ] },
          { "id": "p2", "name": "banner_300x250", "format": "banner", "size": {"width": 300, "height": 250},
            "bidding": [], "waterfall": [ {"network": "admob", "adUnitId": "a2", "floor": 0.5} ] },
          { "id": "p3", "name": "banner_adaptive", "format": "banner", "size": null, "adaptive": true,
            "waterfall": [ {"network": "chartboost", "adUnitId": "c1", "floor": 0.15} ] },
          { "id": "p4", "name": "interstitial", "format": "interstitial", "size": null,
            "waterfall": [ {"network": "admob", "adUnitId": "a3", "floor": 0.5} ] }
        ]
      },
      "connectedNetworks": { "meta": {}, "admob": {"app_id": "ca-app"}, "yandex": {}, "pangle": {"app_id": "8876"},
                             "chartboost": {"app_id": "cb"}, "inmobi": {"account_id": "acc"} }
    }
    """

    func testAConfigWithoutConnectedNetworksGatesNothing() {
        let config = parse(#"{"mediation":{"placements":[]}}"#)
        XCTAssertNil(config.gate(.pangle))
        XCTAssertEqual(config.enabledNetworks, AdvergicAdNetwork.allCases)
    }

    func testOnlyConnectedNetworksWithAPlacementMayStart() {
        let config = parse(sample)
        // Bidding band first, then waterfall, in published order; pangle's only entry is disabled.
        XCTAssertEqual(config.enabledNetworks, [.meta, .admobTest, .yandex, .chartboost])
        XCTAssertNil(config.gate(.meta))
        XCTAssertNotNil(config.gate(.liftoff))
    }

    func testAConnectedNetworkNobodyReferencesStaysDown() {
        XCTAssertEqual(parse(sample).gate(.inMobi), "INMOBI is connected but no placement references it")
    }

    func testAnEmptyConnectedNetworksReallyDoesDisableEverything() {
        let config = parse(#"{"connectedNetworks":{},"mediation":{"placements":[]}}"#)
        XCTAssertTrue(config.enabledNetworks.isEmpty)
        XCTAssertNotNil(config.gate(.admobTest))
    }

    func testCredentialsComeOffTheConnectedNetwork() {
        let config = parse(sample)
        XCTAssertEqual(config.platform(.pangle)?.credential("app_id"), "8876")
        XCTAssertNil(config.platform(.meta)?.credential("app_id"))
    }

    func testTestFlagsRideAlongInTheCredentialsObject() {
        let config = parse(#"{"connectedNetworks":{"meta":{"test_mode":"true","test_devices":" a, b ,,c "}}}"#)
        XCTAssertEqual(config.platform(.meta)?.testMode, true)
        XCTAssertEqual(config.platform(.meta)?.testDevices, ["a", "b", "c"])

        let boolean = parse(#"{"connectedNetworks":{"meta":{"test_mode":false}}}"#)
        XCTAssertEqual(boolean.platform(.meta)?.testMode, false)
    }

    func testAnOmittedTestModeLeavesTheLocalSettingAlone() {
        let config = parse(#"{"connectedNetworks":{"meta":{}}}"#)
        XCTAssertNil(config.platform(.meta)?.testMode)
        let setup = AdvergicNetworkSetup(network: .meta, config: AdvergicConfig(metaTestMode: true),
                                         platform: config.platform(.meta))
        XCTAssertTrue(setup.testMode(fallback: true))
    }

    func testServerCredentialsWinOverLocalOnes() {
        let config = parse(sample)
        let setup = AdvergicNetworkSetup(network: .pangle, config: AdvergicConfig(), platform: config.platform(.pangle))
        XCTAssertEqual(setup.credential("app_id", fallback: "local"), "8876")
        XCTAssertEqual(setup.credential("missing", fallback: "local"), "local")
    }

    func testPlacementsKeepTheirBandsApart() {
        let placement = parse(sample).placements[0]
        XCTAssertEqual(placement.bidding.map(\.network), [.meta])
        XCTAssertEqual(placement.waterfall.map(\.network), [.admobTest, .yandex, .pangle])
        XCTAssertNil(placement.bidding[0].floor)
        XCTAssertEqual(placement.waterfall[0].floor, 0.5)
    }

    func testADisabledEntryDoesNotEnableItsNetwork() {
        XCTAssertEqual(parse(sample).gate(.pangle), "PANGLE is connected but no placement references it")
    }

    func testUnknownNetworksAreIgnoredRatherThanFatal() {
        let config = parse(#"{"connectedNetworks":{"madeup":{},"meta":{}},"mediation":{"placements":[{"name":"b","format":"banner","waterfall":[{"network":"madeup","adUnitId":"x"},{"network":"meta","adUnitId":"m"}]}]}}"#)
        XCTAssertEqual(config.enabledNetworks, [.meta])
        XCTAssertEqual(config.placements[0].waterfall.count, 1)
    }

    func testFormerNetworkNamesAreAccepted() {
        XCTAssertEqual(RemoteAdsConfig.network(forId: "Vungle"), .liftoff)
        XCTAssertEqual(RemoteAdsConfig.network(forId: " facebook "), .meta)
        XCTAssertEqual(RemoteAdsConfig.network(forId: "fyber"), .digitalTurbine)
        XCTAssertEqual(RemoteAdsConfig.network(forId: "levelplay"), .ironSource)
        XCTAssertEqual(RemoteAdsConfig.network(forId: "unity"), .unityAds)
        XCTAssertEqual(RemoteAdsConfig.network(forId: "admob_test"), .admobTest)
    }

    func testEntriesMissingAnAdUnitOrFormatAreDropped() {
        let config = parse(#"{"connectedNetworks":{"admob":{}},"mediation":{"placements":[{"name":"x","waterfall":[{"network":"admob","adUnitId":"a"}]},{"name":"y","format":"banner","waterfall":[{"network":"admob","adUnitId":" "},{"network":"admob","adUnitId":"ok"}]}]}}"#)
        XCTAssertEqual(config.placements.map(\.name), ["y"])
        XCTAssertEqual(config.placements[0].waterfall.map(\.adUnitId), ["ok"])
    }

    func testTheDefaultNetworkFallsBackToTheFirstEnabledOne() {
        XCTAssertEqual(parse(sample).defaultNetwork(preferred: .liftoff), .meta)
        XCTAssertEqual(parse(sample).defaultNetwork(preferred: .yandex), .yandex)
    }

    func testTheDefaultSurvivesAConfigThatEnablesNothing() {
        let config = parse(#"{"connectedNetworks":{}}"#)
        XCTAssertEqual(config.defaultNetwork(preferred: .admobTest), .admobTest)
    }

    func testTheGateReasonNamesTheNetworkAndTheCause() {
        XCTAssertEqual(parse(sample).gate(.liftoff), "LIFTOFF is not connected for this app — the SDK will not start it")
    }

    func testTheVersionIsReadOffTheMediationBlock() {
        XCTAssertEqual(parse(sample).version, 5)
    }

    func testASizedSlotMatchesThePlacementOfThatExactShape() {
        let config = parse(sample)
        XCTAssertEqual(config.placement(for: "banner", width: 320, height: 50)?.name, "banner_320x50")
        XCTAssertEqual(config.placement(for: "banner", width: 300, height: 250)?.name, "banner_300x250")
    }

    func testAnUnmatchedSizeFallsBackToTheAdaptivePlacement() {
        XCTAssertEqual(parse(sample).placement(for: "banner", width: 728, height: 90)?.name, "banner_adaptive")
    }

    func testAFullscreenFormatResolvesWithoutASize() {
        XCTAssertEqual(parse(sample).placement(for: "interstitial")?.name, "interstitial")
        XCTAssertNil(parse(sample).placement(for: "rewarded"))
    }

    func testCandidatesCarryEveryEnabledEntryFromBothBands() {
        XCTAssertEqual(parse(sample).placements[0].candidates().map(\.adUnitId), ["m1", "a1", "y1"])
    }

    func testTheShippedExampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/mediation-config.example.json")
        let config = RemoteAdsConfig.parse(parseJSON(try String(contentsOf: url)))
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(config.placements.count, 8)
        XCTAssertEqual(config.enabledNetworks.first, .meta)
        XCTAssertEqual(config.placement(for: "app_open")?.candidates().count, 3) // pangle disabled
    }
}
