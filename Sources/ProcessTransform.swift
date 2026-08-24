import Foundation

@_silgen_name("HubProcessFindRprojArgument")
func HubProcessFindRprojArgument(_ pid: pid_t) -> UnsafeMutablePointer<CChar>?

@_silgen_name("HubProcessFindInitialProject")
func HubProcessFindInitialProject(_ pid: pid_t) -> UnsafeMutablePointer<CChar>?

@_silgen_name("HubProcessTransformHideFromDock")
func HubProcessTransformHideFromDock(_ pid: pid_t) -> Bool

@_silgen_name("HubProcessTransformShowInDock")
func HubProcessTransformShowInDock(_ pid: pid_t) -> Bool

enum ProcessTransform {
    @discardableResult
    static func hideFromDock(pid: pid_t) -> Bool {
        let ok = HubProcessTransformHideFromDock(pid)
        if !ok {
            // Avoid flooding logs when TransformProcessType is unavailable.
            return false
        }
        ActivityLogger.shared.log("processTransform.hide pid=\(pid) ok=true")
        return true
    }

    @discardableResult
    static func showInDock(pid: pid_t) -> Bool {
        let ok = HubProcessTransformShowInDock(pid)
        ActivityLogger.shared.log("processTransform.show pid=\(pid) ok=\(ok)")
        return ok
    }
}
