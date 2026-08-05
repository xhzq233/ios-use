#include <CoreFoundation/CoreFoundation.h>
#include <sqlite3.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int report(const char *case_id, int passed) {
    char message[96];
    int length = snprintf(
        message,
        sizeof(message),
        "%s %s\n",
        case_id,
        passed ? "PASS" : "FAIL"
    );
    if (length > 0 && (size_t)length < sizeof(message)) {
        (void)write(
            passed ? STDOUT_FILENO : STDERR_FILENO,
            message,
            (size_t)length
        );
    }
    return passed ? 0 : 1;
}

static int write_all(int descriptor, const void *bytes, size_t length) {
    const unsigned char *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(descriptor, cursor, length);
        if (written > 0) {
            cursor += (size_t)written;
            length -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

static int read_exact(int descriptor, void *bytes, size_t length) {
    unsigned char *cursor = bytes;
    while (length > 0) {
        ssize_t count = read(descriptor, cursor, length);
        if (count > 0) {
            cursor += (size_t)count;
            length -= (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

static int parse_u64(const char *value, uint64_t *result) {
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (
        errno != 0 ||
        end == value ||
        end == NULL ||
        *end != '\0'
    ) {
        return -1;
    }
    *result = (uint64_t)parsed;
    return 0;
}

static int is_owned_regular(const struct stat *status, mode_t mode) {
    return S_ISREG(status->st_mode) &&
        status->st_uid == geteuid() &&
        status->st_nlink == 1 &&
        (status->st_mode & 07777) == mode;
}

static int same_file(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev &&
        left->st_ino == right->st_ino;
}

static int is_owned_single_link(
    const struct stat *status,
    mode_t expected_type
) {
    return
        (status->st_mode & S_IFMT) == expected_type &&
        status->st_uid == geteuid() &&
        status->st_nlink == 1;
}

static int capture_owned_descriptor(
    int descriptor,
    mode_t expected_type,
    struct stat *result
) {
    return
        fstat(descriptor, result) == 0 &&
        is_owned_single_link(result, expected_type)
        ? 0
        : -1;
}

static int capture_owned_path(
    const char *path,
    mode_t expected_type,
    struct stat *result
) {
    return
        lstat(path, result) == 0 &&
        is_owned_single_link(result, expected_type)
        ? 0
        : -1;
}

static int path_matches(
    const char *path,
    const struct stat *expected,
    mode_t expected_type
) {
    struct stat observed;
    return
        capture_owned_path(path, expected_type, &observed) == 0 &&
        same_file(expected, &observed)
        ? 0
        : -1;
}

static int path_is_absent(const char *path) {
    struct stat status;
    errno = 0;
    return lstat(path, &status) != 0 && errno == ENOENT ? 0 : -1;
}

static int path_is_absent_or_matches(
    const char *path,
    const struct stat *expected,
    mode_t expected_type
) {
    return
        path_is_absent(path) == 0 ||
        path_matches(path, expected, expected_type) == 0
        ? 0
        : -1;
}

static int run_file_case(const char *path) {
    static const char first[] = "run-create-write";
    static const char second[] = "-read-unlink";
    char observed[sizeof(first) + sizeof(second) - 2];
    struct stat created;
    struct stat status;
    int tracked = 0;
    int descriptor = open(
        path,
        O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
        0600
    );
    int passed = descriptor >= 0;
    if (descriptor >= 0) {
        if (
            capture_owned_descriptor(descriptor, S_IFREG, &created) == 0
        ) {
            tracked = 1;
        } else {
            passed = 0;
        }
        if (
            !tracked ||
            fchmod(descriptor, 0600) != 0 ||
            fstat(descriptor, &status) != 0 ||
            !is_owned_regular(&status, 0600) ||
            !same_file(&created, &status) ||
            path_matches(path, &created, S_IFREG) != 0
        ) {
            passed = 0;
        }
    }
    if (
        passed &&
        (
            write_all(descriptor, first, sizeof(first) - 1) != 0 ||
            write_all(descriptor, second, sizeof(second) - 1) != 0 ||
            lseek(descriptor, 0, SEEK_SET) != 0 ||
            read_exact(descriptor, observed, sizeof(observed)) != 0 ||
            memcmp(
                observed,
                "run-create-write-read-unlink",
                sizeof(observed)
            ) != 0
        )
    ) {
        passed = 0;
    }
    if (descriptor >= 0 && tracked) {
        if (
            path_matches(path, &created, S_IFREG) != 0 ||
            unlink(path) != 0 ||
            path_is_absent(path) != 0
        ) {
            passed = 0;
        }
    }
    if (descriptor >= 0 && close(descriptor) != 0) {
        passed = 0;
    }
    return report("PCAP-RUN-FILE", passed);
}

static int bind_socket(
    const char *path,
    int should_succeed,
    int expected_errno
) {
    struct sockaddr_un address;
    size_t path_length = strlen(path);
    if (path_length == 0 || path_length >= sizeof(address.sun_path)) {
        return -1;
    }
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    address.sun_len = (uint8_t)sizeof(address);
    memcpy(address.sun_path, path, path_length + 1);
    errno = 0;
    int bound = bind(
        descriptor,
        (const struct sockaddr *)&address,
        sizeof(address)
    );
    int bind_errno = errno;
    int passed;
    if (should_succeed) {
        passed = bound == 0;
    } else {
        passed = bound != 0 && bind_errno == expected_errno;
    }
    if (bound == 0) {
        struct stat created;
        if (capture_owned_path(path, S_IFSOCK, &created) != 0) {
            passed = 0;
        }
        if (should_succeed && listen(descriptor, 1) != 0) {
            passed = 0;
        }
    }
    if (close(descriptor) != 0) {
        passed = 0;
    }
    return passed ? 0 : -1;
}

static int run_socket_case(const char *path) {
    return report(
        "PCAP-RUN-SOCKET",
        bind_socket(path, 1, 0) == 0
    );
}

static int log_append_case(
    const char *path,
    uint64_t expected_device,
    uint64_t expected_inode
) {
    static const char marker[] = "probe-append\n";
    struct stat opened;
    struct stat named;
    int descriptor = open(
        path,
        O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
    );
    int passed = descriptor >= 0;
    if (
        passed &&
        (
            fstat(descriptor, &opened) != 0 ||
            !is_owned_regular(&opened, 0600) ||
            (uint64_t)opened.st_dev != expected_device ||
            (uint64_t)opened.st_ino != expected_inode ||
            lstat(path, &named) != 0 ||
            !same_file(&opened, &named) ||
            write_all(descriptor, marker, sizeof(marker) - 1) != 0 ||
            fstat(descriptor, &named) != 0 ||
            !same_file(&opened, &named)
        )
    ) {
        passed = 0;
    }
    if (descriptor >= 0 && close(descriptor) != 0) {
        passed = 0;
    }
    return report("PCAP-LOG-APPEND", passed);
}

static int sqlite_execute(sqlite3 *database, const char *sql) {
    char *error = NULL;
    int result = sqlite3_exec(database, sql, NULL, NULL, &error);
    sqlite3_free(error);
    return result == SQLITE_OK ? 0 : -1;
}

static int sqlite_expect_value(sqlite3 *database) {
    sqlite3_stmt *statement = NULL;
    int passed =
        sqlite3_prepare_v2(
            database,
            "SELECT value FROM capability WHERE id = 1",
            -1,
            &statement,
            NULL
        ) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW;
    if (passed) {
        const unsigned char *value = sqlite3_column_text(statement, 0);
        passed = value != NULL &&
            strcmp((const char *)value, "committed") == 0 &&
            sqlite3_step(statement) == SQLITE_DONE;
    }
    if (statement != NULL && sqlite3_finalize(statement) != SQLITE_OK) {
        passed = 0;
    }
    return passed ? 0 : -1;
}

static int sqlite_expect_text(
    sqlite3 *database,
    const char *sql,
    const char *expected
) {
    sqlite3_stmt *statement = NULL;
    int passed =
        sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            NULL
        ) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_ROW;
    if (passed) {
        const unsigned char *value = sqlite3_column_text(statement, 0);
        passed = value != NULL &&
            strcmp((const char *)value, expected) == 0 &&
            sqlite3_step(statement) == SQLITE_DONE;
    }
    if (statement != NULL && sqlite3_finalize(statement) != SQLITE_OK) {
        passed = 0;
    }
    return passed ? 0 : -1;
}

static int append_suffix(
    char *output,
    size_t output_size,
    const char *path,
    const char *suffix
) {
    int length = snprintf(output, output_size, "%s%s", path, suffix);
    return length > 0 && (size_t)length < output_size ? 0 : -1;
}

static int close_database(sqlite3 **database) {
    if (*database == NULL) {
        return 0;
    }
    if (sqlite3_close(*database) != SQLITE_OK) {
        return -1;
    }
    *database = NULL;
    return 0;
}

static int sqlite_case(const char *database_path) {
    char wal_path[PATH_MAX];
    char shm_path[PATH_MAX];
    char journal_path[PATH_MAX];
    if (
        append_suffix(wal_path, sizeof(wal_path), database_path, "-wal") != 0 ||
        append_suffix(shm_path, sizeof(shm_path), database_path, "-shm") != 0 ||
        append_suffix(
            journal_path,
            sizeof(journal_path),
            database_path,
            "-journal"
        ) != 0
    ) {
        return report("PCAP-PLAYCHAIN-SQLITE", 0);
    }

    sqlite3 *writer = NULL;
    sqlite3 *reader = NULL;
    sqlite3 *reopened = NULL;
    sqlite3_stmt *statement = NULL;
    struct stat database_created;
    struct stat database_status;
    struct stat wal_status;
    struct stat shm_status;
    int database_tracked = 0;
    int wal_tracked = 0;
    int shm_tracked = 0;

    int reservation = open(
        database_path,
        O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
        0600
    );
    int passed = reservation >= 0;
    if (reservation >= 0) {
        if (
            capture_owned_descriptor(
                reservation,
                S_IFREG,
                &database_created
            ) == 0
        ) {
            database_tracked = 1;
        } else {
            passed = 0;
        }
        if (
            !database_tracked ||
            fchmod(reservation, 0600) != 0 ||
            fstat(reservation, &database_status) != 0 ||
            !is_owned_regular(&database_status, 0600) ||
            !same_file(&database_created, &database_status) ||
            path_matches(
                database_path,
                &database_created,
                S_IFREG
            ) != 0
        ) {
            passed = 0;
        }
        if (close(reservation) != 0) {
            passed = 0;
        }
    }
    if (
        passed &&
        (
            path_is_absent(wal_path) != 0 ||
            path_is_absent(shm_path) != 0 ||
            path_is_absent(journal_path) != 0
        )
    ) {
        passed = 0;
    }
    if (
        passed &&
        sqlite3_open_v2(
            database_path,
            &writer,
            SQLITE_OPEN_READWRITE |
                SQLITE_OPEN_FULLMUTEX |
                SQLITE_OPEN_NOFOLLOW,
            NULL
        ) != SQLITE_OK
    ) {
        passed = 0;
    }
    if (
        passed &&
        sqlite_expect_text(writer, "PRAGMA journal_mode=WAL", "wal") != 0
    ) {
        passed = 0;
    }
    if (
        passed &&
        sqlite_execute(
            writer,
            "CREATE TABLE capability("
            "id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
        ) != 0
    ) {
        passed = 0;
    }
    if (passed && sqlite_execute(writer, "BEGIN IMMEDIATE") != 0) {
        passed = 0;
    }
    if (
        passed &&
        sqlite3_prepare_v2(
            writer,
            "INSERT INTO capability(id, value) VALUES(1, ?1)",
            -1,
            &statement,
            NULL
        ) == SQLITE_OK &&
        sqlite3_bind_text(
            statement,
            1,
            "committed",
            -1,
            SQLITE_STATIC
        ) == SQLITE_OK &&
        sqlite3_step(statement) == SQLITE_DONE
    ) {
    } else {
        passed = 0;
    }
    if (statement != NULL) {
        if (sqlite3_finalize(statement) != SQLITE_OK) {
            passed = 0;
        }
        statement = NULL;
    }
    if (passed && sqlite_execute(writer, "COMMIT") != 0) {
        passed = 0;
    }

    if (
        writer != NULL &&
        (
            lstat(database_path, &database_status) != 0 ||
            !is_owned_regular(&database_status, 0600) ||
            !same_file(&database_created, &database_status)
        )
    ) {
        passed = 0;
    }
    if (
        writer != NULL &&
        capture_owned_path(wal_path, S_IFREG, &wal_status) == 0 &&
        is_owned_regular(&wal_status, 0600)
    ) {
        wal_tracked = 1;
    } else if (writer != NULL) {
        passed = 0;
    }
    if (
        writer != NULL &&
        capture_owned_path(shm_path, S_IFREG, &shm_status) == 0 &&
        is_owned_regular(&shm_status, 0600)
    ) {
        shm_tracked = 1;
    } else if (writer != NULL) {
        passed = 0;
    }
    if (
        passed &&
        (
            sqlite3_open_v2(
                database_path,
                &reader,
                SQLITE_OPEN_READONLY |
                    SQLITE_OPEN_FULLMUTEX |
                    SQLITE_OPEN_NOFOLLOW,
                NULL
            ) != SQLITE_OK ||
            sqlite_expect_value(reader) != 0
        )
    ) {
        passed = 0;
    }
    if (close_database(&reader) != 0) {
        passed = 0;
    }
    if (close_database(&writer) != 0) {
        passed = 0;
    }

    if (
        passed &&
        (
            sqlite3_open_v2(
                database_path,
                &reopened,
                SQLITE_OPEN_READONLY |
                    SQLITE_OPEN_FULLMUTEX |
                    SQLITE_OPEN_NOFOLLOW,
                NULL
            ) != SQLITE_OK ||
            sqlite_expect_value(reopened) != 0
        )
    ) {
        passed = 0;
    }
    if (close_database(&reopened) != 0) {
        passed = 0;
    }

    if (statement != NULL) {
        if (sqlite3_finalize(statement) != SQLITE_OK) {
            passed = 0;
        }
        statement = NULL;
    }

    int retained_evidence_valid =
        reader == NULL &&
        writer == NULL &&
        reopened == NULL;
    if (
        retained_evidence_valid &&
        (
            !database_tracked ||
            path_matches(
                database_path,
                &database_created,
                S_IFREG
            ) != 0
        )
    ) {
        retained_evidence_valid = 0;
    }
    if (
        retained_evidence_valid &&
        wal_tracked &&
        path_is_absent_or_matches(
            wal_path,
            &wal_status,
            S_IFREG
        ) != 0
    ) {
        retained_evidence_valid = 0;
    }
    if (
        retained_evidence_valid &&
        shm_tracked &&
        path_is_absent_or_matches(
            shm_path,
            &shm_status,
            S_IFREG
        ) != 0
    ) {
        retained_evidence_valid = 0;
    }
    if (
        path_is_absent(journal_path) != 0
    ) {
        retained_evidence_valid = 0;
    }
    passed = passed && retained_evidence_valid;
    return report("PCAP-PLAYCHAIN-SQLITE", passed);
}

static int expect_open_eperm(
    const char *path,
    int flags,
    mode_t mode
) {
    errno = 0;
    int descriptor = open(path, flags, mode);
    int open_errno = errno;
    if (descriptor >= 0) {
        (void)close(descriptor);
        return -1;
    }
    return open_errno == EPERM ? 0 : -1;
}

static int denied_directory_case(
    const char *case_id,
    const char *sentinel,
    const char *create_path
) {
    int passed =
        expect_open_eperm(
            sentinel,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            0
        ) == 0 &&
        expect_open_eperm(
            sentinel,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            0
        ) == 0 &&
        expect_open_eperm(
            create_path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600
        ) == 0;
    return report(case_id, passed);
}

static int denied_socket_case(const char *case_id, const char *path) {
    return report(case_id, bind_socket(path, 0, EPERM) == 0);
}

static int symlink_escape_case(const char *path) {
    errno = 0;
    int read_descriptor = open(path, O_RDONLY | O_CLOEXEC);
    int read_errno = errno;
    if (read_descriptor >= 0) {
        (void)close(read_descriptor);
    }
    errno = 0;
    int write_descriptor = open(
        path,
        O_WRONLY | O_APPEND | O_CLOEXEC
    );
    int write_errno = errno;
    if (write_descriptor >= 0) {
        (void)close(write_descriptor);
    }
    int passed =
        read_descriptor < 0 &&
        read_errno == EPERM &&
        write_descriptor < 0 &&
        write_errno == EPERM;
    return report("PCAP-DENY-SYMLINK-ESCAPE", passed);
}

static CFPropertyListRef read_property_list(const char *path) {
    int descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return NULL;
    }
    struct stat status;
    if (
        fstat(descriptor, &status) != 0 ||
        !S_ISREG(status.st_mode) ||
        status.st_size <= 0 ||
        status.st_size > 1024 * 1024
    ) {
        (void)close(descriptor);
        return NULL;
    }
    size_t length = (size_t)status.st_size;
    unsigned char *bytes = malloc(length);
    if (bytes == NULL || read_exact(descriptor, bytes, length) != 0) {
        free(bytes);
        (void)close(descriptor);
        return NULL;
    }
    (void)close(descriptor);
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault,
        bytes,
        (CFIndex)length
    );
    free(bytes);
    if (data == NULL) {
        return NULL;
    }
    CFErrorRef error = NULL;
    CFPropertyListRef property_list = CFPropertyListCreateWithData(
        kCFAllocatorDefault,
        data,
        kCFPropertyListImmutable,
        NULL,
        &error
    );
    CFRelease(data);
    if (error != NULL) {
        CFRelease(error);
    }
    if (
        property_list != NULL &&
        CFGetTypeID(property_list) != CFDictionaryGetTypeID()
    ) {
        CFRelease(property_list);
        return NULL;
    }
    return property_list;
}

static int compare_entitlements(const char *left_path, const char *right_path) {
    CFPropertyListRef left = read_property_list(left_path);
    CFPropertyListRef right = read_property_list(right_path);
    int passed =
        left != NULL &&
        right != NULL &&
        CFEqual(left, right);
    if (left != NULL) {
        CFRelease(left);
    }
    if (right != NULL) {
        CFRelease(right);
    }
    return report("PCAP-ENTITLEMENTS-EQUAL", passed);
}

static int run_capabilities(int argc, char **argv) {
    if (argc != 15) {
        return report("PCAP-USAGE", 0);
    }
    uint64_t log_device = 0;
    uint64_t log_inode = 0;
    if (
        parse_u64(argv[5], &log_device) != 0 ||
        parse_u64(argv[6], &log_inode) != 0
    ) {
        return report("PCAP-USAGE", 0);
    }
    if (run_file_case(argv[2]) != 0) {
        return 1;
    }
    if (run_socket_case(argv[3]) != 0) {
        return 1;
    }
    if (log_append_case(argv[4], log_device, log_inode) != 0) {
        return 1;
    }
    if (sqlite_case(argv[7]) != 0) {
        return 1;
    }
    if (
        denied_directory_case(
            "PCAP-DENY-STATE",
            argv[8],
            argv[9]
        ) != 0
    ) {
        return 1;
    }
    if (
        denied_directory_case(
            "PCAP-DENY-PREPARED",
            argv[10],
            argv[11]
        ) != 0
    ) {
        return 1;
    }
    if (
        denied_socket_case(
            "PCAP-DENY-LOGS-SOCKET",
            argv[12]
        ) != 0
    ) {
        return 1;
    }
    if (
        denied_socket_case(
            "PCAP-DENY-PLAYCHAIN-SOCKET",
            argv[13]
        ) != 0
    ) {
        return 1;
    }
    if (symlink_escape_case(argv[14]) != 0) {
        return 1;
    }
    return report("PCAP-PROBE", 1);
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "compare-entitlements") == 0) {
        return compare_entitlements(argv[2], argv[3]);
    }
    if (argc >= 2 && strcmp(argv[1], "run") == 0) {
        return run_capabilities(argc, argv);
    }
    return report("PCAP-USAGE", 0);
}
