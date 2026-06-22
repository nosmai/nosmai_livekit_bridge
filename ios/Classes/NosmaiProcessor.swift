import Foundation
import CoreVideo

/// Runtime bridge to the Nosmai SDK (the `NosmaiFlutterPlugin` class registered by
/// nosmai_camera_sdk). We call into it by selector so this package needs no
/// compile-time dependency on the Nosmai SDK.
@objc class NosmaiProcessor: NSObject {

    /// Processes a CVPixelBuffer in place via NosmaiFlutterPlugin.
    /// Returns true if Nosmai handled the frame, false if the SDK was unavailable.
    @objc static func process(_ buffer: CVPixelBuffer, shouldFlip: Bool) -> Bool {
        guard let cls = NSClassFromString("NosmaiFlutterPlugin") as? NSObject.Type else {
            return false
        }

        let selector = NSSelectorFromString("processExternalPixelBuffer:shouldFlip:")
        guard cls.responds(to: selector) else {
            return false
        }

        let method = class_getClassMethod(cls, selector)
        typealias ProcessFunc = @convention(c) (AnyClass, Selector, CVPixelBuffer, Bool) -> Bool
        let implementation = method_getImplementation(method!)
        let processFunc = unsafeBitCast(implementation, to: ProcessFunc.self)

        return processFunc(cls, selector, buffer, shouldFlip)
    }

    /// Notifies the Nosmai SDK of a camera switch, if the SDK exposes the selector.
    @objc static func notifyCameraSwitch() {
        guard let cls = NSClassFromString("NosmaiFlutterPlugin") as? NSObject.Type else {
            return
        }

        let selector = NSSelectorFromString("notifyCameraSwitch")
        guard cls.responds(to: selector) else {
            return
        }

        let method = class_getClassMethod(cls, selector)
        typealias NotifyFunc = @convention(c) (AnyClass, Selector) -> Void
        let implementation = method_getImplementation(method!)
        let notifyFunc = unsafeBitCast(implementation, to: NotifyFunc.self)

        notifyFunc(cls, selector)
    }
}
