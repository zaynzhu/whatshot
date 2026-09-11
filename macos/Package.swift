// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "WhatShot",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "WhatShotCore",
      targets: ["WhatShotCore"]
    ),
    .executable(
      name: "WhatShotApp",
      targets: ["WhatShotApp"]
    )
  ],
  targets: [
    .target(
      name: "WhatShotCore",
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "WhatShotApp",
      dependencies: ["WhatShotCore"]
    ),
    .testTarget(
      name: "WhatShotCoreTests",
      dependencies: ["WhatShotCore"]
    )
  ]
)