// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "TreeSitterLanguages",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "TreeSitterJavaScriptRunestone", targets: ["TreeSitterJavaScriptRunestone"]),
        .library(name: "TreeSitterJSONRunestone", targets: ["TreeSitterJSONRunestone"]),
    ],
    dependencies: [
        .package(url: "https://github.com/simonbs/Runestone", revision: "ffd8697cd1f02e9e60099f835d110da7a02ff635")
    ],
    targets: [
        .target(name: "TreeSitterJavaScript", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaScriptQueries", resources: [.copy("highlights-jsx.scm"), .copy("highlights-params.scm"), .copy("highlights.scm"), .copy("injections.scm"), .copy("locals.scm"), .copy("tags.scm"), .copy("folds.scm")]),
        .target(name: "TreeSitterJavaScriptRunestone", dependencies: ["Runestone", "TreeSitterJavaScript", "TreeSitterJavaScriptQueries"]),
        .target(name: "TreeSitterJSON", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJSONQueries", resources: [.copy("highlights.scm"), .copy("folds.scm")]),
        .target(name: "TreeSitterJSONRunestone", dependencies: ["Runestone", "TreeSitterJSON", "TreeSitterJSONQueries"]),
    ]
)
