import CoreGraphics

enum FnKeyPolicy {
    static let keyCode: Int64 = 63

    static func isDown(flags: CGEventFlags) -> Bool {
        flags.contains(.maskSecondaryFn)
    }

    static func hasConflictingModifiers(flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
    }

    static func flags(for isDown: Bool, preserving original: CGEventFlags) -> CGEventFlags {
        var result = original
        if isDown {
            result.insert(.maskSecondaryFn)
        } else {
            result.remove(.maskSecondaryFn)
        }
        return result
    }
}
