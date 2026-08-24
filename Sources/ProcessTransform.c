#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <sys/types.h>

enum {
    kHubProcessTransformToForegroundApplication = 1,
    // Background keeps the menu bar when frontmost; UI Element (4) strips it.
    kHubProcessTransformToBackgroundApplication = 2
};

bool HubProcessTransformHideFromDock(pid_t pid) {
    ProcessSerialNumber psn = {0, kNoProcess};
    if (GetProcessForPID(pid, &psn) != noErr) {
        return false;
    }
    return TransformProcessType(&psn, kHubProcessTransformToBackgroundApplication) == noErr;
}

bool HubProcessTransformShowInDock(pid_t pid) {
    ProcessSerialNumber psn = {0, kNoProcess};
    if (GetProcessForPID(pid, &psn) != noErr) {
        return false;
    }
    return TransformProcessType(&psn, kHubProcessTransformToForegroundApplication) == noErr;
}
