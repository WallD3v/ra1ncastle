#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/socket.h>

/* Bind AF_INET outbound sockets for one child process to BIND_SOURCE_IPV4.
 * This keeps repo/git on the physical uplink without changing global routes. */
int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    static int (*real_connect)(int, const struct sockaddr *, socklen_t);
    const char *source;
    struct sockaddr_in bind_addr = { .sin_family = AF_INET };

    if (!real_connect)
        real_connect = dlsym(RTLD_NEXT, "connect");
    source = getenv("BIND_SOURCE_IPV4");
    if (source && addr && addr->sa_family == AF_INET &&
        inet_pton(AF_INET, source, &bind_addr.sin_addr) == 1)
        bind(fd, (const struct sockaddr *)&bind_addr, sizeof(bind_addr));
    return real_connect(fd, addr, len);
}
