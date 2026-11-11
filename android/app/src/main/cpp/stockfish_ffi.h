#ifndef MOVEMENTOR_STOCKFISH_FFI_H
#define MOVEMENTOR_STOCKFISH_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Callback invoked asynchronously for each complete UCI output line.
/// The string pointer is heap-allocated with malloc and MUST be freed
/// by the receiver via sf_ffi_free().
typedef void (*SfLineCallback)(char* line);

/// Callback invoked once when the Stockfish UCI worker thread exits.
typedef void (*SfExitCallback)(int32_t exit_code);

/// Starts the persistent Stockfish UCI loop on a dedicated background thread.
/// [binary_dir_hint] may point to the directory holding the extracted NNUE file
/// (used to synthesize argv[0] = "<dir>/stockfish"). Pass NULL or empty to use ".".
/// Returns 0 on success, -1 if already running or invalid arguments.
int32_t sf_ffi_start(
    const char* binary_dir_hint,
    SfLineCallback on_line,
    SfExitCallback on_exit);

/// Enqueues a single UCI command line (e.g. "uci", "go nodes 500000") to stdin.
/// Returns 0 on success, -1 if engine is not running.
int32_t sf_ffi_send(const char* command);

/// Requests graceful UCI shutdown ("quit" + EOF) and waits for the worker thread.
void sf_ffi_stop(void);

/// Frees heap strings allocated by sf_ffi for SfLineCallback.
void sf_ffi_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif  // MOVEMENTOR_STOCKFISH_FFI_H
