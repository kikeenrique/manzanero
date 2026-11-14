// Deterministic clock/transport tests; no device or Apple framework required.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
typedef void *xpc_remote_connection_t;
static int g_failures, sends, barrier, fail_at, sleep_error, interrupted;
static int64_t now_ns, sent_at[8];
static uint8_t pending[58], sent[8][58];
int manzanero_make_raw_report(const uint8_t *bytes, long size, void *words) {
    assert(size == 58); memcpy(pending, bytes, 58); memset(words, 0, 16); return 16;
}
static int mock_send(xpc_remote_connection_t remote, const void *words, uint64_t service) {
    (void)remote; (void)words; assert(service == 257); assert(sends < 8);
    sent_at[sends] = now_ns;
    memcpy(sent[sends++], pending, 58);
    now_ns += 1000000; // Transport latency must not accumulate into future offsets.
    return sends == fail_at ? 1 : 0;
}
static int (*coredevice_send_universalhid_hid_report)(xpc_remote_connection_t, const void *, uint64_t) = mock_send;
static void note_result(const char *name, int result) { (void)name; if (result) g_failures++; }
static void send_coredevice_hid_barrier(xpc_remote_connection_t remote, unsigned delay) { (void)remote; (void)delay; barrier++; }
static int test_clock(clockid_t clock, struct timespec *value) {
    assert(clock == CLOCK_MONOTONIC); value->tv_sec = now_ns / 1000000000; value->tv_nsec = now_ns % 1000000000; return 0;
}
static int test_sleep(const struct timespec *value, struct timespec *remaining) {
    (void)remaining;
    if (sleep_error) { errno = EINVAL; return -1; }
    if (interrupted) { interrupted = 0; errno = EINTR; return -1; }
    now_ns += value->tv_sec * 1000000000LL + value->tv_nsec; return 0;
}
#define clock_gettime test_clock
#define nanosleep test_sleep
#include "multitouch.inc"
#include "gesture.inc"

static void reset(void) { sends = barrier = g_failures = fail_at = sleep_error = interrupted = 0; now_ns = 0; }
int main(void) {
    // Keep the older sender linked in this standalone include-based test.
    (void)manzanero_multitouch;
    char hex[4][117];
    uint8_t frames[4][58] = {{0}};
    const char *args[15] = {"helper", "device", "action", "feature", "0", "cd_gesture", "257", "0", hex[0], "2", hex[1], "5", hex[2], "8", hex[3]};
    for (int f = 0; f < 4; f++) {
        frames[f][0] = 9; frames[f][1] = 2; frames[f][2] = 5; frames[f][40] = 2;
        frames[f][3] = f < 2 ? 0xc0 : 0; // First contact lifts before the second.
        frames[f][8] = (f == 1 || f == 2) ? 0xc1 : 1;
        frames[f][4] = f ? 50 : 10;
        frames[f][9] = f ? 80 : 0;
        for (int b = 0; b < 58; b++) snprintf(hex[f] + b * 2, 3, "%02x", frames[f][b]);
    }
    manzanero_gesture(NULL, 15, args);
    assert(sends == 5 && barrier == 1 && g_failures == 0);
    assert(sent_at[0] == 0 && sent_at[1] == 2000000 && sent_at[2] == 5000000 && sent_at[3] == 8000000);
    assert(sent[2][3] == 0 && sent[2][8] == 0xc1 && sent[4][3] == 0 && sent[4][8] == 1);
    for (int failure = 1; failure <= 5; failure++) {
        reset(); fail_at = failure;
        manzanero_gesture(NULL, 15, args);
        assert(g_failures == 1 && barrier == 1);
        assert(sends == (failure < 5 ? failure + 1 : 5));
        assert(sent[sends - 1][3] == 0 && sent[sends - 1][8] == 1);
        assert(sent[sends - 1][4] == sent[sends - 2][4]);
    }
    reset(); sleep_error = 1;
    manzanero_gesture(NULL, 15, args);
    assert(g_failures == 1 && sends == 2 && barrier == 1 && sent[1][4] == 10);
    reset(); interrupted = 1;
    manzanero_gesture(NULL, 15, args);
    assert(g_failures == 0 && sends == 5 && sent_at[2] == 5000000);
    for (int invalid = 0; invalid < 10; invalid++) {
        reset();
        for (int b = 0; b < 58; b++) snprintf(hex[3] + b * 2, 3, "%02x", frames[3][b]);
        const char *saved = args[invalid < 3 ? 6 : 13];
        if (invalid < 3) args[6] = invalid == 0 ? "-1" : invalid == 1 ? "18446744073709551616" : "257junk";
        else if (invalid < 5) args[13] = invalid == 3 ? "5" : "10001";
        else if (invalid == 5) hex[3][0] = 'z'; // Validate the final frame before sending.
        else if (invalid == 6) { hex[3][6] = 'c'; hex[3][7] = '0'; } // Final active contact.
        else if (invalid == 7) { hex[3][8] = 'f'; hex[3][9] = 'f'; } // Released contact moves.
        else if (invalid == 8) { hex[3][70] = '0'; hex[3][71] = '1'; } // Reserved byte set.
        else { hex[3][2] = '0'; hex[3][3] = '3'; } // Slot count changes.
        manzanero_gesture(NULL, 15, args);
        assert(g_failures == 1 && sends == 0 && barrier == 0);
        args[invalid < 3 ? 6 : 13] = saved;
    }
    puts("Native timed gesture sender tests passed");
}
