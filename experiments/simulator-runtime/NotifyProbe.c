// Exercise real cross-process notification delivery and shared state.
#include <dispatch/dispatch.h>
#include <arpa/inet.h>
#include <errno.h>
#include <mach/mach.h>
#include <notify.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern uint32_t notify_register_plain(const char *, int *);
static volatile sig_atomic_t receivedSignal;
static void receiveSignal(int signal) { receivedSignal = 1; }

static int publishInChild(const char *executable, const char *name) {
    pid_t child = 0;
    char *arguments[] = {(char *)executable, (char *)name, NULL};
    if (posix_spawn(&child, executable, NULL, NULL, arguments, environ)) return 74;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 74;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 74;
}

// The coordinator holds three registrations with the same logical name: one
// native host and two separate runtime brokers. Each must retain its own state.
static int holdState(char **argv) {
    const char *name = argv[2];
    uint64_t expected = strtoull(argv[3], NULL, 10), actual = 0;
    int ready = atoi(argv[4]), release = atoi(argv[5]), token = -1;
    uint32_t status = notify_register_check(name, &token);
    if (!status) status = notify_set_state(token, expected);
    if (write(ready, &status, sizeof(status)) != sizeof(status)) return 76;
    close(ready);
    char byte;
    if (!status && read(release, &byte, 1) != 1) status = NOTIFY_STATUS_FAILED;
    close(release);
    if (!status) status = notify_get_state(token, &actual);
    if (token >= 0) notify_cancel(token);
    fprintf(stderr, "[notify-scope] expected=%llu actual=%llu status=%u\n", expected, actual, status);
    return !status && actual == expected ? 0 : 76;
}

int main(int argc, char **argv) {
    if (argc == 6 && !strcmp(argv[1], "--scope")) return holdState(argv);
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
    int tokens[] = {-1, -1, -1, -1, -1, -1};
    mach_port_t port = MACH_PORT_NULL;
    int fd = -1;
    struct sigaction action = {.sa_handler = receiveSignal};
    sigemptyset(&action.sa_mask);
    sigaction(SIGUSR1, &action, NULL);
    uint32_t registration = notify_register_dispatch(name, &tokens[0],
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(int deliveredToken) {
            if (!notify_get_state(deliveredToken, &state)) dispatch_semaphore_signal(received);
        });
    if (!registration) registration = notify_register_check(name, &tokens[1]);
    if (!registration) registration = notify_register_plain(name, &tokens[2]);
    if (!registration) registration = notify_register_mach_port(name, &port, 0, &tokens[3]);
    if (!registration) registration = notify_register_file_descriptor(name, &fd, 0, &tokens[4]);
    if (!registration) registration = notify_register_signal(name, SIGUSR1, &tokens[5]);
    if (registration) {
        fprintf(stderr, "[notify-probe] registration failed=%u\n", registration);
        for (int i = 0; i < 6; ++i) if (tokens[i] >= 0) notify_cancel(tokens[i]);
        return 73;
    }
    int changed = 0;
    notify_check(tokens[1], &changed); // Clear the initial registration event.
    int status = publishInChild(argv[0], name);
    long timeout = dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    struct { mach_msg_header_t header; char trailer[512]; } message = {0};
    kern_return_t receivedPort = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0, sizeof(message), port, 5000, MACH_PORT_NULL);
    struct pollfd pending = {.fd = fd, .events = POLLIN};
    int polled;
    do { polled = poll(&pending, 1, 5000); } while (polled < 0 && errno == EINTR);
    uint32_t fdToken = 0;
    int receivedFD = polled > 0 && read(fd, &fdToken, sizeof(fdToken)) == sizeof(fdToken)
        && ntohl(fdToken) == tokens[4];
    uint32_t checked = notify_check(tokens[1], &changed);
    for (int attempt = 0; !receivedSignal && attempt < 100; ++attempt) usleep(10000);
    int passed = !status && !timeout && state == 42 && !receivedPort
        && message.header.msgh_id == tokens[3] && receivedFD && receivedSignal && !checked && changed;
    for (int i = 0; i < 6; ++i) {
        uint64_t value = 0;
        passed &= !notify_get_state(tokens[i], &value) && value == 42;
        passed &= !notify_cancel(tokens[i]);
        passed &= notify_get_state(tokens[i], &value) == NOTIFY_STATUS_INVALID_TOKEN;
    }
    fprintf(stderr, "[notify-probe] child=%d dispatch=%d mach=%d fd=%d signal=%d changed=%d state=%llu passed=%d\n",
            status, !timeout, !receivedPort, receivedFD, receivedSignal, changed, state, passed);

    // self.* belongs to libnotify's process-local implementation, including
    // when all other notifications are mapped into a host namespace.
    snprintf(name, sizeof(name), "self.io.iosuse.runtime-probe.notify.%d", getpid());
    int selfToken = -1;
    uint64_t selfState = 0;
    uint32_t selfStatus = notify_register_check(name, &selfToken);
    if (!selfStatus) selfStatus = notify_set_state(selfToken, 11);
    if (!selfStatus) selfStatus = notify_check(selfToken, &changed);
    if (!selfStatus) selfStatus = publishInChild(argv[0], name);
    if (!selfStatus) selfStatus = notify_get_state(selfToken, &selfState);
    if (!selfStatus) selfStatus = notify_check(selfToken, &changed);
    passed &= !selfStatus && selfState == 11 && !changed;
    if (selfToken >= 0) notify_cancel(selfToken);
    fprintf(stderr, "[notify-probe] self status=%u state=%llu childEvent=%d\n", selfStatus, selfState, changed);
    return passed ? 0 : 75;
}
