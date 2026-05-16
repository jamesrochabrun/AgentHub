#if __has_include("/opt/homebrew/include/git2.h")
#include "/opt/homebrew/include/git2.h"
#elif __has_include("/usr/local/include/git2.h")
#include "/usr/local/include/git2.h"
#elif __has_include_next(<git2.h>)
#include_next <git2.h>
#else
#error "libgit2 headers were not found. Install libgit2 from https://github.com/libgit2/libgit2 or with `brew install libgit2`."
#endif
