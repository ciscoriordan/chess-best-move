// Plain C interface to the in-process Stockfish engine (Stockfish::Engine from
// src/engine.h). The Swift module ChessEngine is the only intended client. It is
// C rather than C++ so that importing ChessEngine never requires Swift/C++
// interoperability to be enabled in the app target.
//
// Threading rules:
// - sf_engine_create, sf_engine_destroy, sf_engine_set_threads,
//   sf_engine_set_hash and sf_engine_start_search block and must not be called
//   concurrently with each other (use one serial queue).
// - sf_engine_stop_search and sf_engine_wait may be called from any thread.
// - Callbacks run on Stockfish's main search thread. The strings they receive are
//   only valid for the duration of the callback.
//
// Nothing in this interface writes to stdout. Stockfish still calls exit() if a
// memory allocation (network, hash table, search thread state) or pthread_create
// fails; every other exit() path is either unreachable from here or intercepted.

#ifndef CSTOCKFISH_H
#define CSTOCKFISH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sf_engine sf_engine;

typedef enum {
    SF_SCORE_CENTIPAWNS = 0,
    SF_SCORE_MATE       = 1,  // value = moves to mate; negative when the side to move gets mated
} sf_score_kind;

typedef enum {
    SF_BOUND_EXACT = 0,
    SF_BOUND_LOWER = 1,
    SF_BOUND_UPPER = 2,
} sf_bound;

typedef struct {
    int32_t       depth;
    int32_t       sel_depth;  // -1 when not reported
    int32_t       multipv;    // 1-based
    sf_score_kind score_kind;
    int32_t       score_value;
    sf_bound      bound;
    int64_t       nodes;      // -1 when not reported
    int64_t       nps;        // -1 when not reported
    int64_t       time_ms;    // -1 when not reported
    int32_t       hashfull;   // per mille, -1 when not reported
    const char*   pv;         // space-separated UCI moves, may be empty
} sf_info;

// Called for every principal-variation report ("info ... pv") and for the depth-0
// report when the root position has no legal moves.
typedef void (*sf_info_callback)(void* context, const sf_info* info);
// Called exactly once per started search. bestmove is "(none)" when the root
// position has no legal moves. ponder is an empty string when there is none.
typedef void (*sf_bestmove_callback)(void* context, const char* bestmove, const char* ponder);

// "Stockfish 19". Static storage.
const char* sf_engine_version(void);

// File name of the NNUE network this build requires ("nn-<12 hex>.nnue").
// Static storage.
const char* sf_engine_network_file_name(void);

// Constructs the engine (one search thread, 16 MB hash) and loads the network
// named by sf_engine_network_file_name() from network_directory, then verifies it.
// Returns NULL with a message in error (when error is not NULL) if the network is
// missing or invalid.
sf_engine* sf_engine_create(const char* network_directory, char* error, size_t error_size);

// Stops any search, waits for it to finish, then destroys the engine.
void sf_engine_destroy(sf_engine* engine);

// Resize the thread pool / transposition table. Values are clamped to Stockfish's
// limits. Both wait for a running search to finish first.
void sf_engine_set_threads(sf_engine* engine, int32_t threads);
void sf_engine_set_hash(sf_engine* engine, int32_t megabytes);

// Waits for any previous search to finish, sets the position and MultiPV, then
// starts a search and returns immediately. If movetime_ms > 0 the search runs for
// that long; otherwise it runs to the given depth (minimum 1). The search ends on
// its own or after sf_engine_stop_search, and bestmove_callback is then called
// exactly once. Returns a positive search id, or 0 with a message in error
// (invalid FEN, or a position Stockfish cannot search safely: wrong king count, pawns
// on the first or eighth rank, the side not to move in check, more than two
// checkers); no callback is made when 0 is returned.
uint64_t sf_engine_start_search(sf_engine*           engine,
                                const char*          fen,
                                int32_t              movetime_ms,
                                int32_t              depth,
                                int32_t              multipv,
                                sf_info_callback     info_callback,
                                sf_bestmove_callback bestmove_callback,
                                void*                context,
                                char*                error,
                                size_t               error_size);

// Asks the search with this id to stop; it then reports its best move promptly.
// Does nothing if another search, or none, is current. Non-blocking.
void sf_engine_stop_search(sf_engine* engine, uint64_t search_id);

// Blocks until no search is running.
void sf_engine_wait(sf_engine* engine);

#ifdef __cplusplus
}
#endif

#endif  // CSTOCKFISH_H
