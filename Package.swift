// swift-tools-version:5.9
import PackageDescription

/// One adapter module per network and per MMP, each depending on the core and its vendor SDK.
/// Publishers add only the modules they want, or `AdvergicAdKitAll` for everything SPM can ship.
///
/// Not here: Chartboost Mediation and Digital Turbine FairBid publish no Swift package, so their
/// modules ship through `AdvergicAdKit.podspec` only.
struct Module {
    let name: String
    let vendor: [Target.Dependency]
}

let networks: [Module] = [
    Module(name: "AdMob", vendor: [.product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads")]),
    Module(name: "Yandex", vendor: [.product(name: "YandexMobileAds", package: "yandex-ads-sdk-ios")]),
    Module(name: "Meta", vendor: [.product(name: "FBAudienceNetwork", package: "FBAudienceNetwork")]),
    Module(name: "Liftoff", vendor: [.product(name: "VungleAdsSDK", package: "VungleAdsSDK-SwiftPackageManager")]),
    Module(name: "Pangle", vendor: [.product(name: "AdsGlobalPackage", package: "AdsGlobalPackage")]),
    Module(name: "InMobi", vendor: [.product(name: "InMobiSDK", package: "InMobiSDK-Swift-Package")]),
    Module(name: "AppLovin", vendor: [.product(name: "AppLovinSDK", package: "AppLovin-MAX-Swift-Package")]),
    Module(name: "UnityAds", vendor: [.product(name: "UnityAds", package: "Unity-Ads-Swift-Package")]),
    Module(name: "IronSource", vendor: [.product(name: "UnityMediationSDK", package: "LevelPlay-Swift-Package")]),
    Module(name: "Mintegral", vendor: [.product(name: "MintegralAdSDK", package: "MintegralAdSDK-Swift-Package")]),
    Module(name: "BidMachine", vendor: [.product(name: "BidMachine", package: "BidMachine-SPM")]),
]

let mmps: [Module] = [
    Module(name: "AppsFlyer", vendor: [.product(name: "AppsFlyerLib", package: "AppsFlyerFramework")]),
    Module(name: "Singular", vendor: [.product(name: "Singular", package: "Singular-iOS-SDK")]),
    Module(name: "Adjust", vendor: [.product(name: "AdjustSdk", package: "ios_sdk")]),
    Module(name: "Firebase", vendor: [.product(name: "FirebaseAnalytics", package: "firebase-ios-sdk")]),
]

let modules = networks + mmps

let package = Package(
    name: "AdvergicAdKit",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "AdvergicAdKit", targets: ["AdvergicAdKit"]),
        .library(name: "AdvergicAdKitAll", targets: ["AdvergicAdKit"] + modules.map { "AdvergicAdKit\($0.name)" }),
    ] + modules.map { .library(name: "AdvergicAdKit\($0.name)", targets: ["AdvergicAdKit\($0.name)"]) },
    dependencies: [
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "13.0.0"),
        .package(url: "https://github.com/yandexmobile/yandex-ads-sdk-ios.git", from: "8.5.0"),
        .package(url: "https://github.com/facebook/FBAudienceNetwork.git", from: "6.22.0"),
        .package(url: "https://github.com/Vungle/VungleAdsSDK-SwiftPackageManager.git", from: "7.7.7"),
        // Pangle tags its releases as prereleases (`8.3.0-release.7`), which `from:` never matches.
        .package(url: "https://github.com/bytedance/AdsGlobalPackage.git", exact: "8.3.0-release.7"),
        .package(url: "https://github.com/InMobi/InMobiSDK-Swift-Package.git", from: "11.4.1"),
        .package(url: "https://github.com/AppLovin/AppLovin-MAX-Swift-Package.git", from: "13.6.4"),
        .package(url: "https://github.com/Unity-Technologies/Unity-Ads-Swift-Package.git", from: "4.20.1"),
        .package(url: "https://github.com/ironsource-mobile/LevelPlay-Swift-Package.git", from: "9.6.0"),
        .package(url: "https://github.com/Mintegral-official/MintegralAdSDK-Swift-Package.git", from: "8.1.7"),
        .package(url: "https://github.com/bidmachine/BidMachine-SPM.git", from: "3.8.0"),
        .package(url: "https://github.com/AppsFlyerSDK/AppsFlyerFramework.git", from: "7.0.2"),
        .package(url: "https://github.com/singular-labs/Singular-iOS-SDK.git", from: "12.14.2"),
        .package(url: "https://github.com/adjust/ios_sdk.git", from: "5.8.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.0.0"),
    ],
    targets: [
        .target(
            name: "AdvergicAdKit",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "AdvergicAdKitTests",
            dependencies: ["AdvergicAdKit"],
            exclude: ["Fixtures"]
        ),
    ] + modules.map { module in
        .target(
            name: "AdvergicAdKit\(module.name)",
            dependencies: ["AdvergicAdKit"] + module.vendor
        )
    }
)
