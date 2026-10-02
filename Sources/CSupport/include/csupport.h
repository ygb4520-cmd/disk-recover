#ifndef CSUPPORT_H
#define CSUPPORT_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// Unix-socket helpers (the privileged helper hands open disk fds to the app).
int cs_unix_listen(const char *path);                 // returns listening fd or -1
int cs_unix_accept(int listen_fd, int timeout_ms);    // returns client fd, -1 on error/timeout
int cs_unix_connect(const char *path);                // returns fd or -1
int cs_send_fd(int sock, int fd, const void *buf, size_t len);       // 0 on success
ssize_t cs_recv_fd(int sock, int *fd_out, void *buf, size_t len);    // *fd_out = -1 if none
int cs_peer_uid(int sock, uint32_t *uid);             // 0 on success

// Disk geometry via DKIOCGETBLOCKSIZE / DKIOCGETBLOCKCOUNT. 0 on success.
int cs_disk_geometry(int fd, uint32_t *block_size, uint64_t *block_count);

// fcntl wrappers (fcntl is variadic and not callable from Swift).
int cs_set_nocache(int fd);
int cs_full_fsync(int fd);
#endif
