// Standalone sender tests: no Apple frameworks, connection, or device required.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef void *xpc_remote_connection_t;
static int g_failures, sends, barrier, fail_at;
static uint8_t pending[58], sent[32][58];
int manzanero_make_raw_report(const uint8_t *bytes, long size, void *words) {
    assert(size == 58); memcpy(pending, bytes, 58); memset(words, 0, 16); return 16;
}
static int mock_send(xpc_remote_connection_t remote, const void *words, uint64_t service) {
    (void)remote; (void)words; assert(service == 257); assert(sends < 32);
    memcpy(sent[sends++], pending, 58); return sends == fail_at ? 1 : 0;
}
static int (*coredevice_send_universalhid_hid_report)(xpc_remote_connection_t, const void *, uint64_t) = mock_send;
static void note_result(const char *name, int result) { (void)name; if (result) g_failures++; }
static void send_coredevice_hid_barrier(xpc_remote_connection_t remote, unsigned delay) { (void)remote; (void)delay; barrier++; }
#include "multitouch.inc"

int main(void) {
    char hex[32][117];
    const char *args[40] = {"helper", "device", "action", "feature", "0", "cd_multitouch", "257", "30"};
    for (int f = 0; f < 32; f++) {
        uint8_t frame[58] = {9, 2, 5};
        frame[3] = f == 31 ? 0 : 0xc0; frame[8] = f == 31 ? 1 : 0xc1;
        frame[4] = f; frame[9] = 255 - f;
        for (int b = 0; b < 58; b++) snprintf(hex[f] + 2 * b, 3, "%02x", frame[b]);
        args[f + 8] = hex[f];
    }
    manzanero_multitouch(NULL, 40, args);
    assert(sends == 32 && barrier == 1 && g_failures == 0);
    assert(sent[0][4] == 0 && sent[30][4] == 30);
    assert(sent[31][3] == 0 && sent[31][8] == 1 && sent[31][4] == 30);
    for (int failure = 1; failure <= 31; failure += 15) {
        sends = barrier = g_failures = 0; fail_at = failure;
        manzanero_multitouch(NULL, 40, args);
        assert(sends == failure + 1 && barrier == 1 && g_failures == 1);
        assert(sent[failure][3] == 0 && sent[failure][8] == 1);
        assert(sent[failure][4] == sent[failure - 1][4]);
    }
    sends = barrier = g_failures = 0; fail_at = 32;
    manzanero_multitouch(NULL, 40, args);
    assert(g_failures == 1 && sends == 32); // Release failure cannot report success.
    sends = barrier = g_failures = fail_at = 0;
    hex[31][0] = 'z'; // Validate even the final frame before any input is sent.
    manzanero_multitouch(NULL, 40, args);
    assert(sends == 0 && barrier == 0 && g_failures == 1);
    puts("Native multitouch sender tests passed");
}
