#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

/// Copy process argv/env into a newly malloc'd buffer (caller frees).
/// Returns byte length, or -1 on failure.
static int copy_procargs(pid_t pid, char **outBuf) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0 || size == 0) {
        return -1;
    }

    char *buf = (char *)malloc(size);
    if (!buf) {
        return -1;
    }
    if (sysctl(mib, 3, buf, &size, NULL, 0) < 0) {
        free(buf);
        return -1;
    }
    *outBuf = buf;
    return (int)size;
}

/// Returns first absolute *.Rproj / *.rproj path from argv, malloc'd (caller frees), or NULL.
char *HubProcessFindRprojArgument(pid_t pid) {
    char *buf = NULL;
    int size = copy_procargs(pid, &buf);
    if (size < (int)sizeof(int) || !buf) {
        return NULL;
    }

    int argc = 0;
    memcpy(&argc, buf, sizeof(int));
    char *ptr = buf + sizeof(int);
    char *end = buf + size;

    // Skip executable path string.
    while (ptr < end && *ptr != '\0') {
        ptr++;
    }
    while (ptr < end && *ptr == '\0') {
        ptr++;
    }

    char *result = NULL;
    for (int i = 0; i < argc && ptr < end; i++) {
        if (i > 0) {
            size_t len = strnlen(ptr, (size_t)(end - ptr));
            if (len > 6) {
                const char *ext = ptr + len - 6;
                if ((strcmp(ext, ".Rproj") == 0 || strcmp(ext, ".rproj") == 0) && ptr[0] == '/') {
                    result = (char *)malloc(len + 1);
                    if (result) {
                        memcpy(result, ptr, len);
                        result[len] = '\0';
                    }
                    break;
                }
            }
        }
        ptr += strnlen(ptr, (size_t)(end - ptr));
        while (ptr < end && *ptr == '\0') {
            ptr++;
        }
    }

    free(buf);
    return result;
}

/// Returns RS_INITIAL_PROJECT value from environ, malloc'd (caller frees), or NULL.
char *HubProcessFindInitialProject(pid_t pid) {
    char *buf = NULL;
    int size = copy_procargs(pid, &buf);
    if (size < (int)sizeof(int) || !buf) {
        return NULL;
    }

    int argc = 0;
    memcpy(&argc, buf, sizeof(int));
    char *ptr = buf + sizeof(int);
    char *end = buf + size;

    // Skip argv strings (argc of them after exe path packing).
    // First skip exe path.
    while (ptr < end && *ptr != '\0') ptr++;
    while (ptr < end && *ptr == '\0') ptr++;
    for (int i = 1; i < argc && ptr < end; i++) {
        ptr += strnlen(ptr, (size_t)(end - ptr));
        while (ptr < end && *ptr == '\0') ptr++;
    }

    char *result = NULL;
    const char *key = "RS_INITIAL_PROJECT=";
    size_t keyLen = strlen(key);
    while (ptr < end) {
        size_t len = strnlen(ptr, (size_t)(end - ptr));
        if (len == 0) {
            ptr++;
            continue;
        }
        if (len > keyLen && strncmp(ptr, key, keyLen) == 0) {
            const char *value = ptr + keyLen;
            size_t vlen = strlen(value);
            result = (char *)malloc(vlen + 1);
            if (result) {
                memcpy(result, value, vlen + 1);
            }
            break;
        }
        ptr += len;
        while (ptr < end && *ptr == '\0') ptr++;
    }

    free(buf);
    return result;
}
