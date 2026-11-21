/*
 * A paired classic-Bluetooth port's iostream on macOS.
 *
 * Behaviour follows libdivecomputer's native RFCOMM transport (bluetooth.c over socket.c), which leaves configure,
 * DTR, RTS, break, flush and purge NULL, so they answer SUCCESS; Subsurface's Qt RFCOMM stream does the same. Opening
 * and reading follow serial_posix.c (O_NONBLOCK, TIOCEXCL, full-or-TIMEOUT reads with one deadline per call). Writes
 * differ from serial_posix.c on purpose: no tcdrain, and a bounded wait for room, so a link that dropped can't block.
 * The stream is new code for LibDCSwift. Its error mapping (libdc_btserial_status), raw-mode configure, line mapping
 * (get_lines) and close sequence follow libdivecomputer's src/serial_posix.c, Copyright (C) 2008 Jef Driesen,
 * LGPL-2.1-or-later. This file is LGPL-2.1, as libdivecomputer.
 */
#include "configuredc.h"

#if TARGET_OS_OSX
#define ENABLE_LOGGING 1
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <libdivecomputer/custom.h>
#include "context-private.h"

typedef struct {
    dc_context_t *context;
    int fd;
    int timeout;
    unsigned int write_limit;
    int exclusive;
    int have_saved;
    struct termios saved;
    int carrier_seen;
} libdc_btserial_t;

// serial_posix.c's syserror.
static dc_status_t libdc_btserial_status(int code)
{
    switch (code) {
    case EINVAL: return DC_STATUS_INVALIDARGS;
    case ENOMEM: return DC_STATUS_NOMEMORY;
    case ENOENT: return DC_STATUS_NODEVICE;
    case EACCES:
    case EBUSY: return DC_STATUS_NOACCESS;
    default: return DC_STATUS_IO;
    }
}

static uint64_t libdc_btserial_now_ms(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000;
}

// A call the pseudo-serial refused: logged, and answered SUCCESS as RFCOMM answers it.
static dc_status_t libdc_btserial_tolerated(libdc_btserial_t *port, const char *call)
{
    int code = errno;
    WARNING(port->context, "%s refused on the paired port (%s); answering SUCCESS, as RFCOMM does", call, strerror(code));
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_failed(libdc_btserial_t *port)
{
    int code = errno;
    SYSERROR(port->context, code);
    return libdc_btserial_status(code);
}

// poll(2) for `events`, retrying EINTR: 1 ready, 0 timed out, -1 error (errno set).
static int libdc_btserial_wait(int fd, short events, int milliseconds)
{
    struct pollfd request = { .fd = fd, .events = events, .revents = 0 };
    while (1) {
        int result = poll(&request, 1, milliseconds);
        if (result >= 0) return result > 0 ? 1 : 0;
        if (errno != EINTR) return -1;
    }
}

static int libdc_btserial_left(uint64_t deadline)
{
    uint64_t now = libdc_btserial_now_ms();
    return deadline > now ? (int)(deadline - now) : 0;
}

bool libdc_btserial_carrier_lost(bool carrier_seen, unsigned int lines)
{
    return carrier_seen && (lines & DC_LINE_DCD) == 0;
}

static dc_status_t libdc_btserial_set_timeout(void *userdata, int timeout)
{
    libdc_btserial_t *port = userdata;
    port->timeout = timeout < 0 ? -1 : timeout;
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_set_break(void *userdata, unsigned int value)
{
    libdc_btserial_t *port = userdata;
    if (ioctl(port->fd, value ? TIOCSBRK : TIOCCBRK, NULL) != 0) return libdc_btserial_tolerated(port, "set_break");
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_modem(libdc_btserial_t *port, int line, unsigned int value, const char *call)
{
    int bits = line;
    if (ioctl(port->fd, value ? TIOCMBIS : TIOCMBIC, &bits) != 0) return libdc_btserial_tolerated(port, call);
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_set_dtr(void *userdata, unsigned int value)
{
    return libdc_btserial_modem(userdata, TIOCM_DTR, value, "set_dtr");
}

static dc_status_t libdc_btserial_set_rts(void *userdata, unsigned int value)
{
    return libdc_btserial_modem(userdata, TIOCM_RTS, value, "set_rts");
}

// As serial_posix.c reads the lines; carrier seen here arms the write gate.
static dc_status_t libdc_btserial_get_lines(void *userdata, unsigned int *value)
{
    libdc_btserial_t *port = userdata;
    int bits = 0;
    if (ioctl(port->fd, TIOCMGET, &bits) != 0) return libdc_btserial_failed(port);
    unsigned int lines = 0;
    if (bits & TIOCM_CAR) lines |= DC_LINE_DCD;
    if (bits & TIOCM_CTS) lines |= DC_LINE_CTS;
    if (bits & TIOCM_DSR) lines |= DC_LINE_DSR;
    if (bits & TIOCM_RNG) lines |= DC_LINE_RNG;
    if (bits & TIOCM_CAR) port->carrier_seen = 1;
    if (value) *value = lines;
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_get_available(void *userdata, size_t *value)
{
    libdc_btserial_t *port = userdata;
    int count = 0;
    if (ioctl(port->fd, FIONREAD, &count) != 0) return libdc_btserial_failed(port);
    if (value) *value = (size_t)count;
    return DC_STATUS_SUCCESS;
}

// serial_posix.c's raw mode, best effort: the RFCOMM link has no line, so nothing here can fail the open.
static dc_status_t libdc_btserial_configure(void *userdata, unsigned int baudrate, unsigned int databits, dc_parity_t parity,
    dc_stopbits_t stopbits, dc_flowcontrol_t flowcontrol)
{
    libdc_btserial_t *port = userdata;
    struct termios tty;
    if (tcgetattr(port->fd, &tty) != 0) return libdc_btserial_tolerated(port, "configure (tcgetattr)");
    tty.c_iflag &= ~(IGNBRK | BRKINT | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF | IXANY);
    tty.c_oflag &= ~OPOST;
    tty.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
    tty.c_cflag |= (CLOCAL | CREAD);
    tty.c_cflag &= ~(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS);
    switch (databits) {
    case 5: tty.c_cflag |= CS5; break;
    case 6: tty.c_cflag |= CS6; break;
    case 7: tty.c_cflag |= CS7; break;
    default: tty.c_cflag |= CS8; break;
    }
    if (parity == DC_PARITY_EVEN || parity == DC_PARITY_ODD) {
        tty.c_cflag |= PARENB | (parity == DC_PARITY_ODD ? PARODD : 0);
        tty.c_iflag |= INPCK;
    } else {
        tty.c_iflag |= IGNPAR;
    }
    if (stopbits == DC_STOPBITS_TWO) tty.c_cflag |= CSTOPB;
    if (flowcontrol == DC_FLOWCONTROL_HARDWARE) tty.c_cflag |= CRTSCTS;
    if (flowcontrol == DC_FLOWCONTROL_SOFTWARE) tty.c_iflag |= IXON | IXOFF;
    tty.c_cc[VMIN] = 1;
    tty.c_cc[VTIME] = 0;
    // On macOS a termios speed is the rate itself.
    cfsetispeed(&tty, (speed_t)baudrate);
    cfsetospeed(&tty, (speed_t)baudrate);
    if (tcsetattr(port->fd, TCSANOW, &tty) != 0) return libdc_btserial_tolerated(port, "configure (tcsetattr)");
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_poll(void *userdata, int timeout)
{
    libdc_btserial_t *port = userdata;
    int ready = libdc_btserial_wait(port->fd, POLLIN, timeout < 0 ? -1 : timeout);
    if (ready < 0) return libdc_btserial_failed(port);
    return ready ? DC_STATUS_SUCCESS : DC_STATUS_TIMEOUT;
}

// Full-or-TIMEOUT, as serial_posix.c and socket.c read: one deadline for the call, a short read keeps its count.
static dc_status_t libdc_btserial_read(void *userdata, void *data, size_t size, size_t *actual)
{
    libdc_btserial_t *port = userdata;
    size_t done = 0;
    const uint64_t deadline = port->timeout > 0 ? libdc_btserial_now_ms() + (uint64_t)port->timeout : 0;
    while (done < size) {
        int wait = port->timeout < 0 ? -1 : (port->timeout == 0 ? 0 : libdc_btserial_left(deadline));
        if (port->timeout > 0 && wait == 0) break;
        int ready = libdc_btserial_wait(port->fd, POLLIN, wait);
        if (ready < 0) {
            if (actual) *actual = done;
            return libdc_btserial_failed(port);
        }
        if (ready == 0) break;
        ssize_t count = read(port->fd, (unsigned char *)data + done, size - done);
        if (count > 0) {
            done += (size_t)count;
        } else if (count == 0) {
            // End of file: the node went, or the link closed it.
            break;
        } else if (errno != EINTR && errno != EAGAIN) {
            if (actual) *actual = done;
            return libdc_btserial_failed(port);
        }
        if (port->timeout == 0 && count <= 0) break;
    }
    if (actual) *actual = done;
    return done == size ? DC_STATUS_SUCCESS : DC_STATUS_TIMEOUT;
}

// Non-blocking writes as the link takes them, never tcdrain; write_limit bounds the whole call, and a write after carrier
// rose and dropped fails at once, as Subsurface refuses a write on a socket that isn't connected.
static dc_status_t libdc_btserial_write(void *userdata, const void *data, size_t size, size_t *actual)
{
    libdc_btserial_t *port = userdata;
    size_t done = 0;
    if (actual) *actual = 0;
    if (port->carrier_seen) {
        int bits = 0;
        unsigned int lines = (ioctl(port->fd, TIOCMGET, &bits) == 0 && (bits & TIOCM_CAR)) ? DC_LINE_DCD : 0;
        if (libdc_btserial_carrier_lost(true, lines)) {
            ERROR(port->context, "Carrier dropped after the paired port's link came up; not writing");
            return DC_STATUS_IO;
        }
    }
    const uint64_t deadline = libdc_btserial_now_ms() + port->write_limit;
    while (done < size) {
        ssize_t count = write(port->fd, (const unsigned char *)data + done, size - done);
        if (count > 0) {
            done += (size_t)count;
            continue;
        }
        if (count < 0 && errno != EAGAIN && errno != EINTR) {
            if (actual) *actual = done;
            return libdc_btserial_failed(port);
        }
        int wait = libdc_btserial_left(deadline);
        int ready = wait > 0 ? libdc_btserial_wait(port->fd, POLLOUT, wait) : 0;
        if (ready < 0) {
            if (actual) *actual = done;
            return libdc_btserial_failed(port);
        }
        if (ready == 0) {
            ERROR(port->context, "No room on the paired port's link for %u ms; %zu of %zu bytes went out", port->write_limit, done, size);
            if (actual) *actual = done;
            return DC_STATUS_TIMEOUT;
        }
    }
    if (actual) *actual = done;
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_ioctl(void *userdata, unsigned int request, void *data, size_t size)
{
    return DC_STATUS_UNSUPPORTED;
}

static dc_status_t libdc_btserial_flush(void *userdata)
{
    return DC_STATUS_SUCCESS;
}

// tcflush drops what an RFCOMM socket keeps (Subsurface's purge does nothing), which is closer to serial; a refusal is let go.
static dc_status_t libdc_btserial_purge(void *userdata, dc_direction_t direction)
{
    libdc_btserial_t *port = userdata;
    int queue = TCIOFLUSH;
    if (direction == DC_DIRECTION_INPUT) queue = TCIFLUSH;
    else if (direction == DC_DIRECTION_OUTPUT) queue = TCOFLUSH;
    if (tcflush(port->fd, queue) != 0) return libdc_btserial_tolerated(port, "purge");
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_btserial_sleep(void *userdata, unsigned int milliseconds)
{
    struct timespec left = { .tv_sec = milliseconds / 1000, .tv_nsec = (long)(milliseconds % 1000) * 1000000 };
    while (nanosleep(&left, &left) != 0 && errno == EINTR) {}
    return DC_STATUS_SUCCESS;
}

// As serial_posix.c closes: restore the line, give up exclusivity, close; every step runs and the first error is kept.
static dc_status_t libdc_btserial_close(void *userdata)
{
    libdc_btserial_t *port = userdata;
    dc_status_t status = DC_STATUS_SUCCESS;
    if (port->have_saved && tcsetattr(port->fd, TCSANOW, &port->saved) != 0) {
        // A pseudo-serial that refused termios at open refuses it here too.
    }
    if (port->exclusive && ioctl(port->fd, TIOCNXCL, NULL) != 0) {
        status = libdc_btserial_failed(port);
    }
    if (close(port->fd) != 0 && status == DC_STATUS_SUCCESS) {
        status = libdc_btserial_failed(port);
    }
    free(port);
    return status;
}

static const dc_custom_cbs_t libdc_btserial_callbacks = {
    .set_timeout = libdc_btserial_set_timeout,
    .set_break = libdc_btserial_set_break,
    .set_dtr = libdc_btserial_set_dtr,
    .set_rts = libdc_btserial_set_rts,
    .get_lines = libdc_btserial_get_lines,
    .get_available = libdc_btserial_get_available,
    .configure = libdc_btserial_configure,
    .poll = libdc_btserial_poll,
    .read = libdc_btserial_read,
    .write = libdc_btserial_write,
    .ioctl = libdc_btserial_ioctl,
    .flush = libdc_btserial_flush,
    .purge = libdc_btserial_purge,
    .sleep = libdc_btserial_sleep,
    .close = libdc_btserial_close,
};

dc_status_t libdc_btserial_open(dc_iostream_t **iostream, dc_context_t *context, const char *path, unsigned int write_limit_ms)
{
    if (iostream == NULL || path == NULL) return DC_STATUS_INVALIDARGS;
    *iostream = NULL;
    libdc_btserial_t *port = calloc(1, sizeof(libdc_btserial_t));
    if (port == NULL) return DC_STATUS_NOMEMORY;
    port->context = context;
    port->timeout = -1;
    port->write_limit = write_limit_ms > 0 ? write_limit_ms : 1;
    port->fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (port->fd < 0) {
        dc_status_t status = libdc_btserial_failed(port);
        free(port);
        return status;
    }
    // An RFCOMM socket has neither exclusivity nor a line to save, so a pseudo-serial that refuses them still opens.
    if (ioctl(port->fd, TIOCEXCL, NULL) == 0) {
        port->exclusive = 1;
    } else {
        int code = errno;
        if (code == EBUSY) {
            close(port->fd);
            free(port);
            return DC_STATUS_NOACCESS;
        }
        WARNING(context, "TIOCEXCL refused on the paired port (%s)", strerror(code));
    }
    if (tcgetattr(port->fd, &port->saved) == 0) {
        port->have_saved = 1;
    } else {
        int code = errno;
        WARNING(context, "tcgetattr refused on the paired port (%s)", strerror(code));
    }
    dc_status_t status = dc_custom_open(iostream, context, DC_TRANSPORT_SERIAL, &libdc_btserial_callbacks, port);
    if (status != DC_STATUS_SUCCESS) {
        *iostream = NULL;
        if (port->exclusive) ioctl(port->fd, TIOCNXCL, NULL);
        close(port->fd);
        free(port);
    }
    return status;
}
#endif
