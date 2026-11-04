// forkgum.c — the Frida form of forkprobe: gum_init_embedded(), then fork().
//
// Gum's Interceptor rewrites shared-cache pages (pthread_setname_np, libdyld
// and libunwind hooks) during initialisation, so the child runs rewritten code
// as soon as libdyld's fork handler returns. Built only when a Frida Gum devkit
// is given to build.zsh; linked statically, no Frida is needed in the guest.

#include "frida-gum.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    gum_init_embedded();
    printf("forkgum: gum initialised, forking\n");
    pid_t pid = fork();
    if (pid < 0) {
        printf("RESULT fork_failed\n");
        return 2;
    }
    if (pid == 0) {
        printf("child: alive after fork\n");
        _exit(0);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        printf("RESULT wait_failed\n");
        return 2;
    }
    if (WIFEXITED(status)) {
        printf("RESULT child_exit=%d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status) == 0 ? 0 : 1;
    }
    if (WIFSIGNALED(status)) {
        printf("RESULT child_signal=%d\n", WTERMSIG(status));
        return 1;
    }
    printf("RESULT child_status=0x%x\n", status);
    return 1;
}
