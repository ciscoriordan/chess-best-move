// Implementation of CStockfish.h on top of Stockfish::Engine (src/engine.h).
//
// Stockfish treats a missing or invalid network as fatal and calls exit() from
// Network::verify() right after handing the error text to the engine's
// "verify network" callback. This bridge installs a callback that throws a C++
// exception for error messages instead, so the exit() is never reached and the
// failure comes back to Swift as an error. Stockfish itself is compiled with
// exceptions enabled for this reason (its Makefile uses -fno-exceptions).

#include "CStockfish.h"

#include <algorithm>
#include <cstdio>
#include <exception>
#include <filesystem>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

#include "attacks.h"
#include "bitboard.h"
#include "engine.h"
#include "evaluate.h"
#include "misc.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "types.h"

namespace {

using Stockfish::Engine;

struct NetworkVerificationError: std::runtime_error {
    using std::runtime_error::runtime_error;
};

void write_error(char* buffer, size_t size, const std::string& message) {
    if (buffer == nullptr || size == 0)
        return;
    std::snprintf(buffer, size, "%s", message.c_str());
}

void global_init() {
    static std::once_flag once;
    std::call_once(once, [] {
        // Same one-time table initialization as Stockfish's main().
        Stockfish::Attacks::init();
        Stockfish::Position::init();
    });
}

void set_option(Stockfish::OptionsMap& options, const std::string& name, long long value) {
    std::istringstream is("name " + name + " value " + std::to_string(value));
    options.setoption(is);
}

struct ScoreWriter {
    sf_info& out;

    void operator()(Stockfish::Score::Mate mate) const {
        // Plies to mate -> moves to mate, same formula as UCIEngine::format_score.
        out.score_kind  = SF_SCORE_MATE;
        out.score_value = (mate.plies > 0 ? (mate.plies + 1) : mate.plies) / 2;
    }

    void operator()(Stockfish::Score::Tablebase tb) const {
        // Same mapping as UCIEngine::format_score. Unreachable without tablebases.
        constexpr int TB_CP = 20000;
        out.score_kind      = SF_SCORE_CENTIPAWNS;
        out.score_value     = (tb.win ? TB_CP : -TB_CP) - tb.plies;
    }

    void operator()(Stockfish::Score::InternalUnits units) const {
        out.score_kind  = SF_SCORE_CENTIPAWNS;
        out.score_value = units.value;
    }
};

void fill_score(sf_info& out, const Stockfish::Score& score) { score.visit(ScoreWriter{out}); }

// Stockfish's FEN parser rejects malformed FENs and some impossible positions (king
// count, pawns on the back ranks, too many pieces) but not positions its search cannot
// handle safely: if the side that just moved is still in check, the search can capture
// the king, and move generation assumes at most two checkers. Reject those here.
std::optional<std::string> unsupported_position(const std::string& fen) {
    using namespace Stockfish;
    StateInfo state;
    Position  pos;
    if (auto err = pos.set(fen, false, &state))
        return std::string(err->what());

    const Color us = pos.side_to_move();
    if (pos.attackers_to(pos.square<KING>(~us)) & pos.pieces(us))
        return std::string("Unsupported position. The side not to move is in check.");
    if (popcount(pos.checkers()) > 2)
        return std::string("Unsupported position. More than two pieces give check.");
    return std::nullopt;
}

}  // namespace

struct sf_engine {
    Engine engine;

    // Guards current_search_id so that a stop request for an old search can never
    // stop a newer one.
    std::mutex search_mutex;
    uint64_t   current_search_id = 0;
    uint64_t   last_search_id    = 0;

    // Targets for the current search. Written only while no search is running
    // (start_search waits first), read on the search thread.
    sf_info_callback     info_callback     = nullptr;
    sf_bestmove_callback bestmove_callback = nullptr;
    void*                context           = nullptr;

    // Engine(path) derives its "binary directory" from path.parent_path() and
    // looks for the default network there, so pointing it at a file inside the
    // network directory loads the network during construction.
    explicit sf_engine(const std::filesystem::path& networkDirectory) :
        engine(std::optional<std::filesystem::path>(networkDirectory / "stockfish")) {

        engine.set_on_verify_network([](std::string_view message) {
            if (message.find("ERROR") != std::string_view::npos)
                throw NetworkVerificationError(std::string(message));
        });

        engine.set_on_start([] {});
        engine.set_on_iter([](const Engine::InfoIter&) {});

        engine.set_on_update_no_moves([this](const Engine::InfoShort& i) {
            sf_info info{};
            info.depth     = i.depth;
            info.sel_depth = -1;
            info.multipv   = 1;
            fill_score(info, i.score);
            info.bound    = SF_BOUND_EXACT;
            info.nodes    = -1;
            info.nps      = -1;
            info.time_ms  = -1;
            info.hashfull = -1;
            info.pv       = "";
            if (info_callback)
                info_callback(context, &info);
        });

        engine.set_on_update_full([this](const Engine::InfoFull& i) {
            const std::string pv(i.pv);
            sf_info           info{};
            info.depth     = i.depth;
            info.sel_depth = i.selDepth;
            info.multipv   = int32_t(i.multiPV);
            fill_score(info, i.score);
            info.bound = i.bound == "lowerbound" ? SF_BOUND_LOWER
                       : i.bound == "upperbound" ? SF_BOUND_UPPER
                                                 : SF_BOUND_EXACT;
            info.nodes    = int64_t(i.nodes);
            info.nps      = int64_t(i.nps);
            info.time_ms  = int64_t(i.timeMs);
            info.hashfull = i.hashfull;
            info.pv       = pv.c_str();
            if (info_callback)
                info_callback(context, &info);
        });

        engine.set_on_bestmove([this](std::string_view bestmove, std::string_view ponder) {
            const std::string best(bestmove), pond(ponder);
            if (bestmove_callback)
                bestmove_callback(context, best.c_str(), pond.c_str());
        });
    }
};

const char* sf_engine_version(void) {
    static const std::string version = Stockfish::engine_version_info();
    return version.c_str();
}

const char* sf_engine_network_file_name(void) { return EvalFileDefaultName; }

sf_engine* sf_engine_create(const char* network_directory, char* error, size_t error_size) {
    if (network_directory == nullptr)
    {
        write_error(error, error_size, "No network directory given.");
        return nullptr;
    }

    global_init();

    sf_engine* e = nullptr;
    try
    {
        e = new sf_engine(Stockfish::path_from_utf8(network_directory));
        // Throws NetworkVerificationError (instead of exiting) if the network
        // did not load.
        e->engine.verify_network();
        return e;
    } catch (const std::exception& ex)
    {
        write_error(error, error_size, ex.what());
    } catch (...)
    {
        write_error(error, error_size, "Unknown error while creating the engine.");
    }
    delete e;
    return nullptr;
}

void sf_engine_destroy(sf_engine* engine) {
    if (engine == nullptr)
        return;
    engine->engine.stop();
    engine->engine.wait_for_search_finished();
    delete engine;
}

void sf_engine_set_threads(sf_engine* engine, int32_t threads) {
    engine->engine.wait_for_search_finished();
    const long long clamped = std::clamp<long long>(threads, 1, Stockfish::MaxThreads);
    set_option(engine->engine.get_options(), "Threads", clamped);
}

void sf_engine_set_hash(sf_engine* engine, int32_t megabytes) {
    engine->engine.wait_for_search_finished();
    const long long clamped = std::clamp<long long>(megabytes, 1, Stockfish::MaxHashMB);
    set_option(engine->engine.get_options(), "Hash", clamped);
}

uint64_t sf_engine_start_search(sf_engine*           engine,
                                const char*          fen,
                                int32_t              movetime_ms,
                                int32_t              depth,
                                int32_t              multipv,
                                sf_info_callback     info_callback,
                                sf_bestmove_callback bestmove_callback,
                                void*                context,
                                char*                error,
                                size_t               error_size) {
    if (fen == nullptr)
    {
        write_error(error, error_size, "No FEN given.");
        return 0;
    }

    try
    {
        engine->engine.wait_for_search_finished();

        if (auto problem = unsupported_position(fen))
        {
            write_error(error, error_size, *problem);
            return 0;
        }

        if (auto err = engine->engine.set_position(fen, {}))
        {
            write_error(error, error_size, err->what());
            return 0;
        }

        set_option(engine->engine.get_options(), "MultiPV",
                   std::clamp<long long>(multipv, 1, Stockfish::MAX_MOVES));

        Stockfish::Search::LimitsType limits;
        limits.startTime = Stockfish::now();
        if (movetime_ms > 0)
            limits.movetime = movetime_ms;
        else
            limits.depth = std::clamp(depth, 1, Stockfish::MAX_PLY - 1);

        std::lock_guard<std::mutex> lock(engine->search_mutex);
        engine->info_callback     = info_callback;
        engine->bestmove_callback = bestmove_callback;
        engine->context           = context;
        const uint64_t id         = ++engine->last_search_id;
        engine->current_search_id = id;
        engine->engine.go(limits);
        return id;
    } catch (const std::exception& ex)
    {
        write_error(error, error_size, ex.what());
    } catch (...)
    {
        write_error(error, error_size, "Unknown error while starting the search.");
    }
    return 0;
}

void sf_engine_stop_search(sf_engine* engine, uint64_t search_id) {
    std::lock_guard<std::mutex> lock(engine->search_mutex);
    if (search_id != 0 && search_id == engine->current_search_id)
        engine->engine.stop();
}

void sf_engine_wait(sf_engine* engine) { engine->engine.wait_for_search_finished(); }
