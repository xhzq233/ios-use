// Exercise real cross-process notification delivery and shared state.
#include <dispatch/dispatch.h>
#include <notify.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc == 2) {
        int token = 0;
        if (notify_register_check(argv[1], &token)) return 71;
        uint32_t status = notify_set_state(token, 42);
        if (!status) status = notify_post(argv[1]);
        notify_cancel(token);
        return status ? 72 : 0;
    }
    char name[96];
    snprintf(name, sizeof(name), "io.iosuse.runtime-probe.notify.%d", getpid());
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block uint64_t state = 0;
    int token = 0;
    uint32_t registration = notify_register_dispatch(name, &token,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(int deliveredToken) {
            if (!notify_get_state(deliveredToken, &state)) dispatch_semaphore_signal(received);
        });
    if (registration) {
        fprintf(stderr, "[notify-probe] registration failed=%u\n", registration);
        return 73;
    }
    pid_t child = 0;
    char *arguments[] = {argv[0], name, NULL};
    int spawn = posix_spawn(&child, argv[0], NULL, NULL, arguments, environ);
    if (spawn) { notify_cancel(token); return 74; }
    int status = 0;
    waitpid(child, &status, 0);
    long timeout = dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    notify_cancel(token);
    fprintf(stderr, "[notify-probe] child=%d delivered=%d state=%llu\n", status, !timeout, state);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 && !timeout && state == 42 ? 0 : 75;
}
