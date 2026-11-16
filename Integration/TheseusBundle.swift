import Foundation

// SwiftPM normally generates this accessor. The standalone macOS build puts
// the same module resources in ThemeBoard.app/Theseus_Theseus.bundle.
// Keep the original Theseus MetalContext.swift byte-for-byte unchanged.
extension Bundle {
    static let module: Bundle = {
        guard let url = Bundle.main.url(forResource: "Theseus_Theseus", withExtension: "bundle"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing Theseus_Theseus.bundle; build with tools/ci-build.sh on macOS")
        }
        return bundle
    }()
}
