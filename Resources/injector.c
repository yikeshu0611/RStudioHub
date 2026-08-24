#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__arm64__)
#include <arm/_mcontext.h>

static const uint8_t kInjectTemplate[] = {
    0xfd, 0x7b, 0xbf, 0xa9,             // stp x29, x30, [sp, #-16]!
    0xfd, 0x03, 0x00, 0x91,             // mov x29, sp
    0x00, 0x00, 0x80, 0xd2,             // mov x0, #0            ; RTLD_NOW placeholder
    0x01, 0x00, 0x00, 0x10,             // adr x1, path          ; placeholder
    0x02, 0x00, 0x00, 0x10,             // adr x2, dlopen_sym    ; placeholder
    0x40, 0x00, 0x3f, 0xd6,             // blr x2
    0x00, 0x00, 0x80, 0x52,             // mov w0, #0
    0x02, 0x00, 0x00, 0x10,             // adr x2, pthread_exit  ; placeholder
    0x40, 0x00, 0x3f, 0xd6,             // blr x2
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // path (256 bytes)
};

enum {
    kPathOffset = 40,
    kPathSize = 256,
    kCodeSize = 296
};

static bool write_remote(task_t task, mach_vm_address_t address, const void *buffer, mach_vm_size_t size) {
    kern_return_t kr = mach_vm_write(task, address, (vm_offset_t)buffer, (mach_msg_type_number_t)size);
    return kr == KERN_SUCCESS;
}

static bool protect_remote(task_t task, mach_vm_address_t address, mach_vm_size_t size) {
    kern_return_t kr = mach_vm_protect(task, address, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return kr == KERN_SUCCESS;
}

static mach_vm_address_t remote_symbol(task_t task, const char *symbol) {
    void *local = dlsym(RTLD_DEFAULT, symbol);
    if (!local) {
        return 0;
    }

    mach_vm_address_t remote = 0;
    kern_return_t kr = mach_vm_remap(
        task,
        &remote,
        sizeof(void *),
        0,
        VM_FLAGS_ANYWHERE,
        mach_task_self(),
        (mach_vm_address_t)local,
        FALSE,
        &remote,
        &remote,
        VM_INHERIT_NONE
    );
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return remote;
}

int rsh_inject_pid(pid_t pid, const char *dylib_path) {
    if (!dylib_path || dylib_path[0] == '\0') {
        return 10;
    }
    if (strlen(dylib_path) >= kPathSize) {
        return 11;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        return 20;
    }

    mach_vm_address_t remote_dlopen = remote_symbol(task, "dlopen");
    mach_vm_address_t remote_pthread_exit = remote_symbol(task, "pthread_exit");
    if (remote_dlopen == 0 || remote_pthread_exit == 0) {
        return 21;
    }

    mach_vm_address_t remote_code = 0;
    kr = mach_vm_allocate(task, &remote_code, kCodeSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        return 22;
    }

    uint8_t code[kCodeSize];
    memset(code, 0, sizeof(code));
    memcpy(code, kInjectTemplate, sizeof(kInjectTemplate));
    strncpy((char *)&code[kPathOffset], dylib_path, kPathSize - 1);

    // Patch ADR offsets for arm64 template.
    int64_t path_delta = (int64_t)(remote_code + kPathOffset) - (int64_t)(remote_code + 12);
    int64_t dlopen_delta = (int64_t)remote_dlopen - (int64_t)(remote_code + 16);
    int64_t exit_delta = (int64_t)remote_pthread_exit - (int64_t)(remote_code + 28);

    *(int32_t *)&code[8] = (int32_t)(path_delta << 0); // placeholder - use simpler approach below
    (void)path_delta;
    (void)dlopen_delta;
    (void)exit_delta;

    // Simpler fallback: use pthread_create_from_mach_thread + dlopen in remote memory via dlopen only.
    // Rewrite with minimal arm64 stub manually.
    uint32_t *ins = (uint32_t *)code;
    ins[0] = 0xa9bf7bfd; // stp x29, x30, [sp, #-16]!
    ins[1] = 0x910003fd; // mov x29, sp
    ins[2] = 0xd2800000; // mov x0, #0
    // adr x1, path @ pc=12, path @ 40 => offset 28
    ins[3] = 0x10000001 | (((kPathOffset - 12) / 4) << 5);
    ins[4] = 0x58000042 | (((((uint64_t)remote_dlopen - (remote_code + 20)) >> 2) & 0x7ffff) << 5); // ldr x2, literal
    ins[5] = 0xd63f0040; // blr x2
    ins[6] = 0x58000042 | (((((uint64_t)remote_pthread_exit - (remote_code + 28)) >> 2) & 0x7ffff) << 5);
    ins[7] = 0xd63f0040; // blr x2

    if (!write_remote(task, remote_code, code, kCodeSize)) {
        return 23;
    }
    if (!protect_remote(task, remote_code, kCodeSize)) {
        return 24;
    }

    thread_act_t thread = MACH_PORT_NULL;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    memset(&state, 0, sizeof(state));
    state.__pc = remote_code;
    state.__sp = 0;
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&state, count, &thread);
#else
    return 30;
#endif
    if (kr != KERN_SUCCESS) {
        return 25;
    }

    return 0;
}

#if defined(RSH_INJECTOR_MAIN)
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <pid> <dylib_path>\n", argv[0]);
        return 1;
    }
    int rc = rsh_inject_pid((pid_t)atoi(argv[1]), argv[2]);
    printf("inject rc=%d\n", rc);
    return rc;
}
#endif
