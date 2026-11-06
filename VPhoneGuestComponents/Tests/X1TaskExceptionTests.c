// A crash reporter must not take the inherited X1 action, but registration
// failures, other tasks and every other exception remain the caller's concern.
#include <assert.h>
#include <mach/mach.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>

static kern_return_t queryResult;
static mach_port_t inheritedPort;
static exception_behavior_t inheritedBehavior;
static thread_state_flavor_t inheritedFlavor;
static unsigned queries;
static unsigned registrations;
static unsigned releasedPorts;
static task_t registeredTask;
static exception_mask_t registeredMask;
static mach_port_t registeredPort;
static exception_behavior_t registeredBehavior;
static thread_state_flavor_t registeredFlavor;
static kern_return_t registrationResult;

static kern_return_t queryPorts(task_t task, exception_mask_t mask,
    exception_mask_t *masks, mach_msg_type_number_t *count, mach_port_t *ports,
    exception_behavior_t *behaviors, thread_state_flavor_t *flavors) {
    assert(task == mach_task_self());
    assert(mask == EXC_MASK_BAD_INSTRUCTION);
    assert(*count == EXC_TYPES_COUNT);
    queries++;
    if (queryResult != KERN_SUCCESS) {
        return queryResult;
    }
    *count = 1;
    masks[0] = mask;
    ports[0] = inheritedPort;
    behaviors[0] = inheritedBehavior;
    flavors[0] = inheritedFlavor;
    return KERN_SUCCESS;
}

static kern_return_t registerPorts(task_t task, exception_mask_t mask,
    mach_port_t port, exception_behavior_t behavior, thread_state_flavor_t flavor) {
    registrations++;
    registeredTask = task;
    registeredMask = mask;
    registeredPort = port;
    registeredBehavior = behavior;
    registeredFlavor = flavor;
    return registrationResult;
}

static kern_return_t releasePort(ipc_space_t task, mach_port_name_t port) {
    assert(task == mach_task_self());
    assert(port == inheritedPort);
    releasedPorts++;
    return KERN_SUCCESS;
}

#define task_get_exception_ports queryPorts
#define task_set_exception_ports registerPorts
#define mach_port_deallocate releasePort
#include "../Shared/VPhoneX1Spawn.c"

static void reset(void) {
    vpX1PortOnce = (pthread_once_t)PTHREAD_ONCE_INIT;
    vpX1Port = MACH_PORT_NULL;
    queryResult = KERN_SUCCESS;
    inheritedPort = 42;
    inheritedBehavior = (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES);
    inheritedFlavor = 0;
    queries = registrations = releasedPorts = 0;
    registeredMask = 0;
    registrationResult = KERN_SUCCESS;
}

static kern_return_t install(exception_mask_t mask) {
    return vpSetTaskExceptionPortsPreservingX1(mach_task_self(), mask, 88,
        EXCEPTION_STATE_IDENTITY, ARM_THREAD_STATE64);
}

static void checkForwarded(exception_mask_t mask) {
    assert(registrations == 1);
    assert(registeredTask == mach_task_self());
    assert(registeredMask == mask);
    assert(registeredPort == 88);
    assert(registeredBehavior == EXCEPTION_STATE_IDENTITY);
    assert(registeredFlavor == ARM_THREAD_STATE64);
}

int main(void) {
    exception_mask_t mixed = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_CRASH;

    reset();
    assert(install(mixed) == KERN_SUCCESS);
    checkForwarded(mixed & ~EXC_MASK_BAD_INSTRUCTION);
    assert(queries == 1 && releasedPorts == 0);
    assert(install(EXC_MASK_BAD_INSTRUCTION) == KERN_SUCCESS);
    assert(registrations == 1 && queries == 1);

    reset();
    registrationResult = KERN_INVALID_ARGUMENT;
    assert(install(mixed) == KERN_INVALID_ARGUMENT);
    checkForwarded(mixed & ~EXC_MASK_BAD_INSTRUCTION);

    reset();
    assert(install(EXC_MASK_BAD_ACCESS) == KERN_SUCCESS);
    checkForwarded(EXC_MASK_BAD_ACCESS);
    assert(queries == 0);

    reset();
    registrationResult = KERN_INVALID_ARGUMENT;
    assert(install(0) == KERN_INVALID_ARGUMENT);
    checkForwarded(0);
    assert(queries == 0);

    reset();
    task_t otherTask = mach_task_self() + 100;
    assert(vpSetTaskExceptionPortsPreservingX1(otherTask, mixed, 99, EXCEPTION_DEFAULT, 0)
        == KERN_SUCCESS);
    assert(queries == 0 && registrations == 1);
    assert(registeredTask == otherTask && registeredMask == mixed && registeredPort == 99);

    reset();
    inheritedPort = MACH_PORT_NULL;
    assert(install(mixed) == KERN_SUCCESS);
    checkForwarded(mixed);
    assert(releasedPorts == 0);

    reset();
    queryResult = KERN_FAILURE;
    assert(install(mixed) == KERN_SUCCESS);
    checkForwarded(mixed);

    reset();
    inheritedBehavior = EXCEPTION_STATE;
    assert(install(mixed) == KERN_SUCCESS);
    checkForwarded(mixed);
    assert(releasedPorts == 1);

    reset();
    inheritedFlavor = ARM_THREAD_STATE64;
    assert(install(mixed) == KERN_SUCCESS);
    checkForwarded(mixed);
    assert(releasedPorts == 1);

    puts("X1TaskExceptionTests: inherited action, forwarding, ownership and failure boundaries passed");
    return 0;
}
