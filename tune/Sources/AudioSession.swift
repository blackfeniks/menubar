import Foundation
import ObjectiveC

enum TuneSession {
    @discardableResult
    static func apply() -> Bool {
        guard let cls = NSClassFromString("AVAudioSession") as? NSObject.Type,
              let shared = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() else {
            Log.line("Audio session: not available")
            return false
        }
        var error: NSError?
        let ok = call(shared, "setEligibleForBTSmartRoutingConsideration:error:", false, &error)
        Log.line(ok ? "Audio session: out of AirPods' automatic switching"
                 : "Audio session: could not leave AirPods' automatic switching (\(error?.localizedDescription ?? "no such call"))")
        return ok
    }

    private static func call(_ target: AnyObject, _ name: String, _ flag: Bool, _ error: inout NSError?) -> Bool {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector), let method = class_getInstanceMethod(object_getClass(target), selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Setter.self)(target, selector, flag, &error)
    }
}
