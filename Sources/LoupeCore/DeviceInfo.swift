import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The machine a note was taken on, as far as a layout bug needs.
///
/// `platform` on `AppInfo` says iPadOS. It does not say *which* iPad, at what scale,
/// on which point release, or whether the window was the whole screen - and a layout
/// bug is not reproducible without those.
///
/// **Nothing identifying, ever.** Not the device name somebody chose for their iPad,
/// not `identifierForVendor`, not an advertising identifier, not a locale. A bundle
/// gets pasted into tickets and public repositories. The moment it carries something
/// a person would not want there, it stops being safe to share - and that costs far
/// more than any field here is worth. `scripts/check-nothing-identifying.py` fails
/// the build on the APIs that would break this, so the rule survives the next agent.
public struct DeviceInfo: Codable, Sendable, Equatable {

    /// The model identifier, `iPad8,3`. What a reader can look up, and the only field
    /// here that is precise.
    public var identifier: String?

    /// The marketing name, `iPad Pro 11-inch`. What a person recognises.
    ///
    /// From an exact-match table, because there is no API for it. A model Loupe has
    /// not been taught leaves this nil rather than guessing: a wrong device name in a
    /// bug report sends somebody to reproduce on the wrong hardware, which is worse
    /// than no name at all. Adding one is a line in `Self.names`.
    public var name: String?

    /// `26.5`. The platform's own name is already on `AppInfo`, so it is not repeated
    /// here - one value, one place, nothing that can disagree with itself.
    public var osVersion: String?

    /// The whole screen. `Annotation.viewport` is the *window*, which on an iPad is
    /// very often smaller - see `isPartOfTheScreen`.
    public var screen: Screen?

    public struct Screen: Codable, Sendable, Equatable {
        /// Points, not pixels. `scale` carries the rest.
        public var width: Double
        public var height: Double
        public var scale: Double

        public init(width: Double, height: Double, scale: Double) {
            self.width = width; self.height = height; self.scale = scale
        }
    }

    public init(identifier: String? = nil,
                name: String? = nil,
                osVersion: String? = nil,
                screen: Screen? = nil) {
        self.identifier = identifier
        self.name = name
        self.osVersion = osVersion
        self.screen = screen
    }
}

public extension DeviceInfo {

    /// Whether a window of this size is only part of the screen - Split View or Slide
    /// Over on an iPad, a resized window on a Mac.
    ///
    /// **This is the field that earns the whole feature.** A screenshot cropped to the
    /// app cannot show it, so a whole class of "it looks wrong" reports arrives with
    /// the cause invisible. Two numbers disagreeing is not something a reader notices;
    /// a sentence saying so is.
    ///
    /// - Parameter viewport: the annotation's own viewport, in points.
    /// - Returns: nil when there is nothing to compare, so a caller can tell "not
    ///   split" from "we do not know".
    func isPartOfTheScreen(viewport: Rect?) -> Bool? {
        guard let screen, let viewport else { return nil }
        // Points, and both come from the same coordinate space. A one-point slack
        // rather than an exact compare: a window inset by a hairline is still the
        // whole screen as far as anybody reading this cares.
        return viewport.width < screen.width - 1 || viewport.height < screen.height - 1
    }
}

// MARK: - Reading it off the machine

public extension DeviceInfo {

    /// What this process is running on. Called by `Loupe.start`, so a host never has
    /// to fill it in and cannot get it wrong.
    static func current() -> DeviceInfo {
        let identifier = modelIdentifier()
        return DeviceInfo(identifier: identifier,
                          name: identifier.flatMap { names[$0] },
                          osVersion: osVersion(),
                          screen: screen())
    }

    /// `iPad8,3`, or nil where the platform has no such thing.
    ///
    /// On a simulator `uname` reports the *host* architecture - `arm64` - which is
    /// true and useless. The simulator says which device it is pretending to be in
    /// its environment, and that is the answer somebody reading the ticket wants.
    private static func modelIdentifier() -> String? {
        if let simulated = ProcessInfo.processInfo
            .environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #if os(macOS)
        return sysctlString("hw.model")
        #elseif canImport(UIKit)
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0)) {
                String(validatingUTF8: $0)
            }
        }
        return (machine?.isEmpty == false) ? machine : nil
        #else
        return nil
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // sysctl writes a C string, so the trailing NUL is part of the buffer and has
        // to go before decoding. Left in, it becomes a stray character in the middle
        // of a table somebody reads.
        let string = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
        return string.isEmpty ? nil : string
    }

    /// `26.5`, or `26.5.1` when there is a patch. Never the build number: it is not
    /// identifying, but it is noise in a table a person reads.
    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func screen() -> Screen? {
        #if canImport(UIKit) && !os(watchOS)
        let screen = UIScreen.main
        return Screen(width: screen.bounds.width,
                      height: screen.bounds.height,
                      scale: screen.scale)
        #elseif canImport(AppKit)
        guard let screen = NSScreen.main else { return nil }
        return Screen(width: screen.frame.width,
                      height: screen.frame.height,
                      scale: screen.backingScaleFactor)
        #else
        return nil
        #endif
    }

    /// Model identifier to marketing name. **Exact match only, never a prefix guess.**
    ///
    /// Deliberately partial, and honest about it: a model that is not here leaves
    /// `name` nil and `identifier` still says exactly what the machine was. Prefix
    /// matching would turn an unknown iPad into a confidently wrong one, which sends
    /// somebody to reproduce a layout bug on hardware that is not the hardware.
    static let names: [String: String] = [
        // Macs report a model identifier too, and a Catalyst build is a Mac.
        "Mac14,2": "MacBook Air (M2)",
        "Mac14,7": "MacBook Pro 13-inch (M2)",
        "Mac15,3": "MacBook Pro 14-inch (M3)",
        "Mac15,6": "MacBook Pro 14-inch (M3 Pro)",
        "Mac15,7": "MacBook Pro 16-inch (M3 Pro)",
        "Mac16,1": "MacBook Pro 14-inch (M4)",
        "Mac16,6": "MacBook Pro 14-inch (M4 Pro)",
        "Mac16,8": "MacBook Pro 16-inch (M4 Pro)",
        "Mac14,3": "Mac mini (M2)",
        "Mac16,10": "Mac mini (M4)",
        "Mac15,12": "MacBook Air 13-inch (M3)",
        "Mac16,12": "MacBook Air 13-inch (M4)",

        "iPad8,1": "iPad Pro 11-inch",
        "iPad8,2": "iPad Pro 11-inch",
        "iPad8,3": "iPad Pro 11-inch",
        "iPad8,4": "iPad Pro 11-inch",
        "iPad8,9": "iPad Pro 11-inch (2nd generation)",
        "iPad8,10": "iPad Pro 11-inch (2nd generation)",
        "iPad13,4": "iPad Pro 11-inch (3rd generation)",
        "iPad13,5": "iPad Pro 11-inch (3rd generation)",
        "iPad13,6": "iPad Pro 11-inch (3rd generation)",
        "iPad13,7": "iPad Pro 11-inch (3rd generation)",
        "iPad14,3": "iPad Pro 11-inch (4th generation)",
        "iPad14,4": "iPad Pro 11-inch (4th generation)",
        "iPad16,3": "iPad Pro 11-inch (M4)",
        "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)",
        "iPad16,6": "iPad Pro 13-inch (M4)",
        "iPad13,8": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
        "iPad14,5": "iPad Pro 12.9-inch (6th generation)",
        "iPad14,6": "iPad Pro 12.9-inch (6th generation)",

        "iPad13,1": "iPad Air (4th generation)",
        "iPad13,2": "iPad Air (4th generation)",
        "iPad13,16": "iPad Air (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8": "iPad Air 11-inch (M2)",
        "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",

        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,2": "iPad mini (6th generation)",
        "iPad16,1": "iPad mini (A17 Pro)",
        "iPad16,2": "iPad mini (A17 Pro)",

        "iPhone14,7": "iPhone 14",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
    ]
}
