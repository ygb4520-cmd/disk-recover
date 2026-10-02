#include "csupport.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <sys/disk.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <string.h>
#include <errno.h>

int cs_unix_listen(const char *path) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) { close(s); errno = ENAMETOOLONG; return -1; }
    strcpy(addr.sun_path, path);
    unlink(path);
    if (bind(s, (struct sockaddr *)&addr, sizeof addr) < 0) { close(s); return -1; }
    chmod(path, 0600);
    if (listen(s, 1) < 0) { close(s); return -1; }
    return s;
}

int cs_unix_accept(int listen_fd, int timeout_ms) {
    struct pollfd p = { .fd = listen_fd, .events = POLLIN };
    int r = poll(&p, 1, timeout_ms);
    if (r <= 0) return -1;
    return accept(listen_fd, NULL, NULL);
}

int cs_unix_connect(const char *path) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) { close(s); errno = ENAMETOOLONG; return -1; }
    strcpy(addr.sun_path, path);
    if (connect(s, (struct sockaddr *)&addr, sizeof addr) < 0) { close(s); return -1; }
    return s;
}

int cs_send_fd(int sock, int fd, const void *buf, size_t len) {
    struct iovec iov = { .iov_base = (void *)buf, .iov_len = len };
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char cbuf[CMSG_SPACE(sizeof(int))];
    if (fd >= 0) {
        memset(cbuf, 0, sizeof cbuf);
        msg.msg_control = cbuf;
        msg.msg_controllen = sizeof cbuf;
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &fd, sizeof(int));
    }
    return sendmsg(sock, &msg, 0) == (ssize_t)len ? 0 : -1;
}

ssize_t cs_recv_fd(int sock, int *fd_out, void *buf, size_t len) {
    *fd_out = -1;
    struct iovec iov = { .iov_base = buf, .iov_len = len };
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char cbuf[CMSG_SPACE(sizeof(int))];
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof cbuf;
    ssize_t n = recvmsg(sock, &msg, 0);
    if (n < 0) return n;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            memcpy(fd_out, CMSG_DATA(c), sizeof(int));
        }
    }
    return n;
}

int cs_peer_uid(int sock, uint32_t *uid) {
    uid_t u; gid_t g;
    if (getpeereid(sock, &u, &g) != 0) return -1;
    *uid = (uint32_t)u;
    return 0;
}

int cs_disk_geometry(int fd, uint32_t *block_size, uint64_t *block_count) {
    uint32_t bs = 0; uint64_t bc = 0;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &bs) != 0) return -1;
    if (ioctl(fd, DKIOCGETBLOCKCOUNT, &bc) != 0) return -1;
    *block_size = bs; *block_count = bc;
    return 0;
}

int cs_set_nocache(int fd) { return fcntl(fd, F_NOCACHE, 1); }
int cs_full_fsync(int fd) { return fcntl(fd, F_FULLFSYNC); }
