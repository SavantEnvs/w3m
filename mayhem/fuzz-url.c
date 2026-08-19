#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <gc.h>
#include "fm.h"

/*
 * Targets parseURL() (url.c) — parses a raw URL string (scheme, user:pass@host:port, path, query,
 * fragment) into a ParsedURL struct. Every URL w3m follows — typed by the user, found as an HTML
 * anchor/form action, read from a bookmark or history file, or handed a base URL via a <base> tag
 * or a proxy setting — goes through this exact parser, so it sees fully attacker-controlled bytes
 * with no prior validation. `current == NULL` (no base URL) matches real call sites (cookie.c,
 * rc.c's proxy-URL parsing, frame.c's initial <base> handling).
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

    /* parseURL mutates/quotes its input in place via url_quote() and expects a NUL-terminated
     * C string; embedded NULs in the fuzz input just truncate the URL early, which is fine. */
    char *url = malloc(size + 1);
    if (!url)
	return 0;
    memcpy(url, data, size);
    url[size] = '\0';

    ParsedURL p_url;
    parseURL(url, &p_url, NULL);

    free(url);
    return 0;
}
