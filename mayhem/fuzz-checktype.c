#include <stdint.h>
#include <stdlib.h>
#include <gc.h>
#include "fm.h"

/*
 * Targets checkType() (etc.c) — turns a raw line (as it comes off the wire/from a file) into
 * per-char display properties, walking backspace ('\b') and ANSI-color escape sequences inline.
 * This exact function shipped an out-of-bounds read/write as recently as edc6026 ("Fix OOB access
 * due to multiple backspaces", fixing an incomplete prior fix at 419ca82d): a run of more
 * backspaces than multi-byte characters seen so far walked `plens` before the start of its
 * buffer. checkType is reachable any time w3m displays fetched text (HTML-rendered or plain), so
 * it sees fully attacker-controlled bytes.
 */

static void *die_oom(size_t bytes) {
    fprintf(stderr, "Out of memory: %lu bytes unavailable!\n", (unsigned long)bytes);
    exit(1);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static int init_done = 0;

    if (!init_done) {
	setenv("GC_LARGE_ALLOC_WARN_INTERVAL", "30000", 1);
	GC_INIT();
#if (GC_VERSION_MAJOR>7) || ((GC_VERSION_MAJOR==7) && (GC_VERSION_MINOR>=2))
	GC_set_oom_fn(die_oom);
#else
	GC_oom_fn = die_oom;
#endif
#ifdef USE_M17N
#ifdef USE_UNICODE
	wtf_init(WC_CES_UTF_8, WC_CES_UTF_8);
#else
	wtf_init(WC_CES_EUC_JP, WC_CES_EUC_JP);
#endif
#endif
	init_done = 1;
    }

    Str s = Strnew_charp_n((char *)data, size);
    Lineprop *prop = NULL;
    Linecolor *color = NULL;
    checkType(s, &prop, &color);
    Strfree(s);

    return 0;
}
