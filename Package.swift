// swift-tools-version:6.0
// Paquete de Grabador: un CLI que graba micrófono y audio del sistema, 100 % local.
import PackageDescription

let package = Package(
    name: "Grabador",
    // macOS 15 es el mínimo porque ScreenCaptureKit solo captura el micrófono desde esa versión
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "grabador", targets: ["Grabador"]),
    ],
    dependencies: [
        // Única dependencia: lee los argumentos del CLI. Se descarga al compilar; el programa no usa red.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Grabador",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    // Modo Swift 5: evita los chequeos estrictos de concurrencia de Swift 6 mientras el prototipo madura
    swiftLanguageModes: [.v5]
)
