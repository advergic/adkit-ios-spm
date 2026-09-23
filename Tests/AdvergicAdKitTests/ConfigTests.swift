import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class ConfigTests: XCTestCase {

    func testEachNetworkFallsBackToItsOwnDefaultAdUnit() {
        let config = AdvergicConfig()
        XCTAssertEqual(config.resolvedBannerAdUnitId(.admobTest), Constants.admobTestBannerAdUnitId)
        XCTAssertEqual(config.resolvedBannerAdUnitId(.yandex), Constants.yandexBannerAdUnitId)
        XCTAssertEqual(config.resolvedFullscreenAdUnitId(.admobTest, format: .rewarded), Constants.admobTestRewardedAdUnitId)
        XCTAssertEqual(config.resolvedFullscreenAdUnitId(.admobTest, format: .appOpen), Constants.admobTestAppOpenAdUnitId)
        XCTAssertEqual(config.resolvedNativeAdUnitId(.admobTest), Constants.admobTestNativeAdUnitId)
    }

    func testAdMobDefaultsAreGooglesIOSTestUnitsNotTheAndroidOnes() {
        let config = AdvergicConfig()
        XCTAssertNotEqual(config.resolvedBannerAdUnitId(.admobTest), "ca-app-pub-3940256099942544/6300978111")
        XCTAssertEqual(Constants.admobTestAppId, "ca-app-pub-3940256099942544~1458002511")
    }

    func testNetworksIssuingOnePlacementPerSizeResolveTheSizeSpecificOne() {
        let config = AdvergicConfig()
        XCTAssertEqual(config.resolvedBannerAdUnitId(.meta, size: .mediumRectangle), Constants.metaMrecPlacementId)
        XCTAssertEqual(config.resolvedBannerAdUnitId(.meta, size: .banner), Constants.metaBannerPlacementId)
        XCTAssertEqual(config.resolvedBannerAdUnitId(.pangle, size: .mediumRectangle), Constants.pangleMrecSlotId)
        XCTAssertEqual(config.resolvedBannerAdUnitId(.liftoff, size: .mediumRectangle), Constants.liftoffMrecPlacementId)
    }

    func testNetworksWithOnePlacementIgnoreTheSize() {
        let config = AdvergicConfig()
        XCTAssertEqual(config.resolvedBannerAdUnitId(.yandex, size: .mediumRectangle),
                       config.resolvedBannerAdUnitId(.yandex, size: .banner))
    }

    func testAnAdUnitOverrideAppliesOnlyToTheConfiguredNetwork() {
        let config = AdvergicConfig(adNetwork: .yandex, bannerAdUnitId: "custom")
        XCTAssertEqual(config.resolvedBannerAdUnitId(.yandex), "custom")
        XCTAssertEqual(config.resolvedBannerAdUnitId(.admobTest), Constants.admobTestBannerAdUnitId)
    }

    func testDefaultsAreTheCredentialFreeNetworkAndThePublisherGate() {
        let config = AdvergicConfig()
        XCTAssertEqual(config.adNetwork, .admobTest)
        XCTAssertTrue(config.requireConfigForAds)
        XCTAssertFalse(config.enableLogging)
        XCTAssertEqual(config.configTimeout, 2.5)
        XCTAssertEqual(config.baseURL, "https://rack.avads.live")
    }

    func testNetworksWithoutAppOpenResolveAPlaceholder() {
        let config = AdvergicConfig()
        for network in [AdvergicAdNetwork.inMobi, .unityAds, .ironSource, .mintegral, .bidMachine, .digitalTurbine] {
            XCTAssertTrue(config.resolvedFullscreenAdUnitId(network, format: .appOpen).hasPrefix("REPLACE_WITH"), "\(network)")
        }
    }

    func testAdSizesCompareByDimensionNotIdentity() {
        XCTAssertEqual(AdvergicAdSize.custom(width: 320, height: 50), .banner)
        XCTAssertNotEqual(AdvergicAdSize.custom(width: 320, height: 51), .banner)
        XCTAssertEqual(AdvergicAdSize.mediumRectangle.description, "300x250")
    }

    func testFormatSlugsMatchTheDashboard() {
        XCTAssertEqual(AdvergicAdFormat.appOpen.configName, "app_open")
        XCTAssertEqual(AdvergicAdFormat.interstitial.configName, "interstitial")
    }

    func testNetworkNamesMatchTheAndroidSdk() {
        XCTAssertEqual(AdvergicAdNetwork.admobTest.name, "ADMOB_TEST")
        XCTAssertEqual(AdvergicAdNetwork.unityAds.name, "UNITY_ADS")
        XCTAssertEqual(AdvergicAdNetwork.digitalTurbine.name, "DIGITAL_TURBINE")
    }

    func testApiKeyValidation() {
        XCTAssertNotNil(Core.validateApiKey(""))
        XCTAssertNotNil(Core.validateApiKey("   "))
        XCTAssertNotNil(Core.validateApiKey("short"))
        XCTAssertNotNil(Core.validateApiKey("adv live key"))
        XCTAssertNil(Core.validateApiKey("adv_live_xxxxxxxx"))
    }
}
