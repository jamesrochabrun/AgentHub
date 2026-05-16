/*
 This is not the upstream libgit2 header.
 It is a SwiftPM system-library shim that forwards to the installed libgit2 headers.
 */

#if __has_include("/opt/homebrew/include/git2.h")
#include "/opt/homebrew/include/git2.h"
#elif __has_include("/usr/local/include/git2.h")
#include "/usr/local/include/git2.h"
#elif __has_include(<git2.h>)
#include <git2.h>
#else
#error "libgit2 headers were not found. Install libgit2 from https://github.com/libgit2/libgit2 or with `brew install libgit2`."
#endif
