#include "capi.h"
#include "../../native/platform/windows/capture.h"

/* Compile the same public header as C, not just C++. */
int md_test_c_header(void) { return md_abi_version() == MD_ABI_VERSION; }
