#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <gc.h>
#include "fm.h"

/*
 * Targets parse_tag() (parsetagx.c) — w3m's HTML tag/attribute tokenizer: given a cursor sitting
 * on '<', it reads the tag name, looks it up in the generated `tagtable` hash, then walks
 * name="value"/'value'/value attribute pairs (quoted, single-quoted, and bare forms) into a
 * `struct parsed_tag`. This is the first thing any fetched HTML page runs through (table.c's
 * renderer and file.c's form handling both call it directly), so it is the natural place for a
 * parser-level memory-safety bug in HTML input to live. Called with internal=TRUE, matching
 * table.c's main-rendering-path usage (accepts INT-flagged internal pseudo-tags too, for wider
 * coverage than the internal=FALSE call sites in frame.c).
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

    /* parse_tag() assumes *s points at '<' and reads a NUL-terminated buffer (it stops on '>' or
     * '\0', never on a length); prepend '<' so every input exercises real tag-parsing, not the
     * "not a tag" bailout. */
    char *buf = malloc(size + 2);
    if (!buf)
	return 0;
    buf[0] = '<';
    memcpy(buf + 1, data, size);
    buf[size + 1] = '\0';

    char *p = buf;
    parse_tag(&p, TRUE);

    free(buf);
    return 0;
}
