// Included by a small patch to the pinned MIT-licensed ipb action sender.
#include <time.h>
#include <errno.h>
extern int manzanero_make_raw_report(const uint8_t *, long, void *);

static int manzanero_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static bool manzanero_send_frame(xpc_remote_connection_t remote, uint64_t service, uint8_t *bytes) {
    uint64_t words[2] = {0, 0};
    if (manzanero_make_raw_report(bytes, 58, words) != sizeof(words)) {
        g_failures++; fprintf(stderr, "Native multitouch report construction failed\n"); return false;
    }
    int result = coredevice_send_universalhid_hid_report(remote, words, service);
    note_result("native multitouch", result);
    return result == 0;
}

static void manzanero_multitouch(xpc_remote_connection_t remote, int argc, const char *argv[]) {
    // Validate the entire bounded sequence before sending any contact.
    uint8_t frames[32][58];
    char *end = NULL;
    uint64_t service = argc > 6 ? strtoull(argv[6], &end, 10) : 0;
    if (!service || !end || *end || argc != 40) goto invalid;
    long milliseconds = strtol(argv[7], &end, 10);
    if (*end || milliseconds < 30 || milliseconds > 10000) goto invalid;
    for (int f = 0; f < 32; f++) {
        const char *hex = argv[f + 8];
        if (strlen(hex) != 116) goto invalid;
        for (int b = 0; b < 58; b++) {
            int hi = manzanero_hex(hex[b * 2]), lo = manzanero_hex(hex[b * 2 + 1]);
            if (hi < 0 || lo < 0) goto invalid;
            frames[f][b] = (hi << 4) | lo;
        }
        uint8_t count = frames[f][1];
        if (frames[f][0] != 9 || count < 2 || count > 5 || frames[f][2] != 5 || count != frames[0][1]) goto invalid;
        for (int id = 0; id < count; id++) {
            if (frames[f][3 + id * 5] != ((f == 31 ? 0 : 0xc0) | id)) goto invalid;
        }
    }
    if (!coredevice_send_universalhid_hid_report) goto invalid;
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int last = 0;
    for (int f = 0; f <= 30; f++) {
        if (f) {
            // Absolute offsets avoid accumulating sleep and transport latency.
            for (;;) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                int64_t elapsed = (now.tv_sec - start.tv_sec) * 1000000000LL + now.tv_nsec - start.tv_nsec;
                int64_t remaining = milliseconds * 1000000LL * f / 30 - elapsed;
                if (remaining <= 0) break;
                struct timespec wait = {remaining / 1000000000LL, remaining % 1000000000LL};
                if (nanosleep(&wait, NULL) != 0 && errno != EINTR) break;
            }
        }
        last = f;
        if (!manzanero_send_frame(remote, service, frames[f])) break;
    }
    // A failed send may have arrived. Release the last attempted positions,
    // rather than moving to the final endpoint after a partial gesture.
    uint8_t release[58];
    memcpy(release, frames[last], sizeof(release));
    for (int id = 0; id < release[1]; id++) release[3 + id * 5] = id;
    manzanero_send_frame(remote, service, release);
    send_coredevice_hid_barrier(remote, 100000);
    return;
invalid:
    g_failures++; fprintf(stderr, "Invalid native multitouch sequence; no contacts sent\n");
}
