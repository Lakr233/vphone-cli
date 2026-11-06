#include "VPhoneX1Spawn.h"

#include <mach/mach.h>
#include <pthread.h>
#include <stdbool.h>

static pthread_once_t vpX1PortOnce = PTHREAD_ONCE_INIT;
static mach_port_t vpX1Port = MACH_PORT_NULL;

static void vpFindInheritedX1Port(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t result = task_get_exception_ports(
        mach_task_self(),
        EXC_MASK_BAD_INSTRUCTION,
        masks,
        &count,
        ports,
        behaviors,
        flavors
    );
    if (result != KERN_SUCCESS) return;

    for (mach_msg_type_number_t index = 0; index < count; index++) {
        bool isX1Action = (masks[index] & EXC_MASK_BAD_INSTRUCTION) != 0 &&
            ports[index] != MACH_PORT_NULL &&
            behaviors[index] == (exception_behavior_t)(
                EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES) &&
            flavors[index] == 0;
        if (isX1Action) {
            // Retain the inherited send right for this process.
            vpX1Port = ports[index];
        } else if (ports[index] != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), ports[index]);
        }
    }
}

static mach_port_t vpInheritedX1Port(void) {
    pthread_once(&vpX1PortOnce, vpFindInheritedX1Port);
    return vpX1Port;
}

kern_return_t vpSetTaskExceptionPortsPreservingX1(
    task_t task,
    exception_mask_t mask,
    mach_port_t port,
    exception_behavior_t behavior,
    thread_state_flavor_t flavor
) {
    // Discover the inherited action before replacing any part of it. A crash
    // reporter's first registration may otherwise steal X1 faults from launchd.
    if (task == mach_task_self() && (mask & EXC_MASK_BAD_INSTRUCTION) != 0 &&
        vpInheritedX1Port() != MACH_PORT_NULL) {
        mask &= ~EXC_MASK_BAD_INSTRUCTION;
        if (mask == 0) {
            return KERN_SUCCESS;
        }
    }
    return task_set_exception_ports(task, mask, port, behavior, flavor);
}

int vpSetSpawnExceptionPortsPreservingX1(
    posix_spawnattr_t *attributes,
    exception_mask_t mask,
    mach_port_t port,
    exception_behavior_t behavior,
    thread_state_flavor_t flavor
) {
    mach_port_t x1Port = vpInheritedX1Port();
    if (x1Port == MACH_PORT_NULL || (mask & EXC_MASK_BAD_INSTRUCTION) == 0) {
        return posix_spawnattr_setexceptionports_np(
            attributes, mask, port, behavior, flavor
        );
    }

    exception_mask_t remaining = mask & ~EXC_MASK_BAD_INSTRUCTION;
    if (remaining != 0) {
        int status = posix_spawnattr_setexceptionports_np(
            attributes, remaining, port, behavior, flavor
        );
        if (status != 0) return status;
    }
    return posix_spawnattr_setexceptionports_np(
        attributes,
        EXC_MASK_BAD_INSTRUCTION,
        x1Port,
        EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
        0
    );
}

int vpSpawnWithInheritedX1Port(
    VPX1SpawnFunction spawn,
    pid_t *restrict pid,
    const char *restrict path,
    const posix_spawn_file_actions_t *restrict actions,
    const posix_spawnattr_t *restrict attributes,
    char *const argv[restrict],
    char *const envp[restrict]
) {
    mach_port_t port = vpInheritedX1Port();
    if (port == MACH_PORT_NULL)
        return spawn(pid, path, actions, attributes, argv, envp);

    posix_spawnattr_t localAttributes = NULL;
    posix_spawnattr_t *childAttributes;
    bool ownsAttributes = attributes == NULL;
    if (ownsAttributes) {
        if (posix_spawnattr_init(&localAttributes) != 0)
            return spawn(pid, path, actions, attributes, argv, envp);
        childAttributes = &localAttributes;
    } else {
        childAttributes = (posix_spawnattr_t *)(void *)attributes;
    }
    int configured = posix_spawnattr_setexceptionports_np(
        childAttributes,
        EXC_MASK_BAD_INSTRUCTION,
        port,
        EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
        0
    );
    if (configured != 0) {
        if (ownsAttributes) posix_spawnattr_destroy(&localAttributes);
        return spawn(pid, path, actions, attributes, argv, envp);
    }
    int status = spawn(pid, path, actions, childAttributes, argv, envp);
    if (ownsAttributes) posix_spawnattr_destroy(&localAttributes);
    return status;
}
