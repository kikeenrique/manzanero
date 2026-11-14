// Reuses the pinned helper's Apple HIDReport bridge and multitouch report layout.
static bool manzanero_unsigned(const char *text, uint64_t *number) {
    if (!text || !*text) return false;
    for (const char *p = text; *p; p++) if (*p < '0' || *p > '9') return false;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || *end) return false;
    *number = value;
    return true;
}

static void manzanero_gesture(xpc_remote_connection_t remote, int argc, const char *argv[]) {
    uint8_t frames[512][58];
    uint64_t times[512], service = 0;
    if (argc < 11 || (argc - 7) % 2 || (argc - 7) / 2 > 512 ||
        !manzanero_unsigned(argv[6], &service) || !service) goto invalid;
    int count = (argc - 7) / 2;
    for (int f = 0; f < count; f++) {
        if (!manzanero_unsigned(argv[7 + f * 2], &times[f]) || times[f] > 10000 ||
            (f == 0 ? times[f] != 0 : times[f] <= times[f - 1])) goto invalid;
        const char *hex = argv[8 + f * 2];
        if (strlen(hex) != 116) goto invalid;
        for (int b = 0; b < 58; b++) {
            int hi = manzanero_hex(hex[b * 2]), lo = manzanero_hex(hex[b * 2 + 1]);
            if (hi < 0 || lo < 0) goto invalid;
            frames[f][b] = (hi << 4) | lo;
        }
        int contacts = frames[f][1];
        if (frames[f][0] != 9 || contacts < 1 || contacts > 5 || frames[f][2] != 5 ||
            contacts != frames[0][1] || frames[f][40] != 2) goto invalid;
        bool active = false;
        for (int id = 0; id < contacts; id++) {
            int offset = 3 + id * 5;
            uint8_t flags = frames[f][offset];
            if (flags != id && flags != (0xc0 | id)) goto invalid;
            if (flags & 0xc0) active = true;
            else if (f && memcmp(&frames[f][offset + 1], &frames[f - 1][offset + 1], 4)) goto invalid;
        }
        if ((f == 0 && !active) || (f == count - 1 && active)) goto invalid;
        // No unvalidated report fields may carry additional HID semantics.
        for (int b = 3 + contacts * 5; b < 58; b++) {
            if (frames[f][b] != (b == 40 ? 2 : 0)) goto invalid;
        }
    }
    if (!coredevice_send_universalhid_hid_report) goto invalid;
    struct timespec start;
    if (clock_gettime(CLOCK_MONOTONIC, &start)) goto invalid;
    int last = 0;
    bool timing_failed = false;
    for (int f = 0; f < count; f++) {
        for (;;) {
            struct timespec now;
            if (clock_gettime(CLOCK_MONOTONIC, &now)) { timing_failed = true; break; }
            int64_t elapsed = (now.tv_sec - start.tv_sec) * 1000000000LL + now.tv_nsec - start.tv_nsec;
            int64_t remaining = (int64_t)times[f] * 1000000LL - elapsed;
            if (remaining <= 0) break;
            struct timespec wait = {remaining / 1000000000LL, remaining % 1000000000LL};
            if (nanosleep(&wait, NULL) && errno != EINTR) { timing_failed = true; break; }
        }
        if (timing_failed) { g_failures++; fprintf(stderr, "Native gesture scheduling failed\n"); break; }
        last = f;
        if (!manzanero_send_frame(remote, service, frames[f])) break;
    }
    // A failed send may have arrived. Release every slot at its last attempted
    // position, even if the sequence was interrupted before its final frame.
    uint8_t release[58];
    memcpy(release, frames[last], sizeof(release));
    for (int id = 0; id < release[1]; id++) release[3 + id * 5] = id;
    manzanero_send_frame(remote, service, release);
    send_coredevice_hid_barrier(remote, 100000);
    return;
invalid:
    g_failures++; fprintf(stderr, "Invalid native gesture; no contacts sent\n");
}
