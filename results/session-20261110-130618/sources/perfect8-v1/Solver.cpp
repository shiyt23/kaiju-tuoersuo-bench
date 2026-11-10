#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>
#include <unordered_map>
#include <future>
#include <thread>
#include <atomic>

// Pure puzzle search: no screen, input, network, or game process access.
struct Move {
    int top, left, bottom, right, count, squares;
};
struct Board {
    int rows = 0, cols = 0;
    std::array<uint8_t, 900> cells{};
    int count() const {
        int n = 0;
        for (int i = 0; i < rows * cols; ++i) n += cells[i] != 0;
        return n;
    }
    // Necessary conditions for partitioning every digit into sum-ten groups.
    // They ignore geometry: false proves a full clear impossible; true does not.
    bool fullClearPossible() const {
        std::array<int, 10> c{};
        int sum = 0, n = 0;
        for (int i = 0; i < rows * cols; ++i) {
            int v = cells[i];
            if (v) { ++c[v]; sum += v; ++n; }
        }
        if (sum % 10 || sum > 5 * n || c[9] > c[1]) return false;
        c[1] -= c[9]; c[9] = 0; // Every nine consumes exactly one one.
        if (c[8] > c[2] + c[1] / 2 || c[7] > c[3] + c[1]) return false;
        for (int limit = 2; limit <= 4; ++limit) {
            int available = 0, required = 0;
            for (int v = 1; v <= limit; ++v) available += v * c[v];
            for (int v = 10 - limit; v <= 8; ++v) required += (10 - v) * c[v];
            if (available < required) return false;
        }
        if (c[5] % 2) {
            unsigned reachable = 1;
            for (int v = 1; v <= 4; ++v)
                for (int k = 0; k < std::min(c[v], 5 / v); ++k) reachable |= reachable << v;
            if (!(reachable & (1U << 5))) return false;
        }
        return true;
    }
    void apply(const Move& m) {
        int sum = 0, count = 0;
        for (int r = m.top; r <= m.bottom; ++r)
            for (int c = m.left; c <= m.right; ++c) {
                auto& v = cells[r * cols + c];
                sum += v;
                count += v != 0;
                v = 0;
            }
        if (sum != 10 || count != m.count) throw std::runtime_error("Invalid planned rectangle");
    }
    bool repairMove(const Move& original, Move& current) const {
        current = original;
        int sum = 0;
        current.count = current.squares = 0;
        for (int r = current.top; r <= current.bottom; ++r)
            for (int c = current.left; c <= current.right; ++c) {
                int value = cells[r * cols + c];
                sum += value;
                if (sum > 10) return false;
                current.count += value != 0;
                current.squares += value * value;
            }
        return sum == 10;
    }
    void moves(std::vector<Move>& out) const {
        out.clear();
        for (int top = 0; top < rows; ++top) {
            std::array<int, 30> sums{};
            for (int bottom = top; bottom < rows; ++bottom) {
                for (int c = 0; c < cols; ++c) sums[c] += cells[bottom * cols + c];
                int right = 0, sum = 0;
                for (int left = 0; left < cols; ++left) {
                    while (right < cols && sum < 10) sum += sums[right++];
                    if (sum == 10 && sums[left] > 0) {
                        // Every action has a unique tight bounding rectangle.
                        bool touchesTop = false, touchesBottom = false;
                        for (int c = left; c < right; ++c) {
                            touchesTop |= cells[top * cols + c] != 0;
                            touchesBottom |= cells[bottom * cols + c] != 0;
                        }
                        if (touchesTop && touchesBottom) {
                            int count = 0, squares = 0;
                            for (int r = top; r <= bottom; ++r)
                                for (int c = left; c < right; ++c) {
                                    int v = cells[r * cols + c];
                                    count += v != 0;
                                    squares += v * v;
                                }
                            out.push_back({top, left, bottom, right - 1, count, squares});
                        }
                    }
                    sum -= sums[left];
                }
            }
        }
    }
};
struct Plan {
    std::vector<Move> moves;
    int score = 0;
    uint64_t signature = 0;
};
class Search {
    struct TailKey {
        std::array<uint64_t, 3> words{};
        bool operator==(const TailKey& other) const { return words == other.words; }
    };
    struct TailHash {
        size_t operator()(const TailKey& key) const {
            uint64_t hash = 1469598103934665603ULL;
            for (auto word : key.words) { hash ^= word; hash *= 1099511628211ULL; }
            return size_t(hash);
        }
    };
    struct Tail { std::vector<Move> moves; int score = 0; bool exact = true; };
    std::unordered_map<TailKey, Tail, TailHash> tails;
    std::chrono::steady_clock::time_point deadline;
    int initialCount;
    bool keepsFullClearPossible(const Board& board, const Move& move) const {
        if (searchMode < 6) return true;
        Board after = board;
        after.apply(move);
        return after.fullClearPossible();
    }
    Tail solveTail(const Board& board, int& nodes) {
        const int limit = searchMode == 7 ? 2000 : 300;
        if (++nodes > limit || std::chrono::steady_clock::now() >= deadline) return {{}, 0, false};
        TailKey key;
        for (int i = 0; i < board.rows * board.cols; ++i) if (board.cells[i]) key.words[i / 64] |= uint64_t(1) << (i % 64);
        auto found = tails.find(key);
        if (found != tails.end()) return found->second;
        std::vector<Move> legal;
        board.moves(legal);
        Tail best;
        for (const auto& move : legal) {
            if (!keepsFullClearPossible(board, move)) continue;
            Board next = board;
            next.apply(move);
            auto child = solveTail(next, nodes);
            best.exact &= child.exact;
            if (move.count + child.score > best.score) {
                best.score = move.count + child.score;
                best.moves.clear();
                best.moves.push_back(move);
                best.moves.insert(best.moves.end(), child.moves.begin(), child.moves.end());
            }
            if (best.score == board.count()) { best.exact = true; break; }
            if (nodes > limit || std::chrono::steady_clock::now() >= deadline) { best.exact = false; break; }
        }
        if (best.exact) tails.emplace(key, best);
        return best;
    }
    const Board initial;
    std::mt19937_64 random;
    std::uniform_real_distribution<double> uniform{0.000001, 0.999999};
    std::vector<Move> actions;
    int searchMode;
    std::vector<double> noiseTable;
public:
    int trials = 0;
    Plan best;
    std::vector<Plan> elite;
    Plan walker;
    explicit Search(const Board& board, uint64_t seed, int mode = 0, double seconds = 32) : initialCount(board.count()), initial(board), random(seed), searchMode(mode) {
        deadline = std::chrono::steady_clock::now() + std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds));
        actions.reserve(256);
        if (searchMode >= 4) {
            noiseTable.resize(65537);
            for (size_t i = 1; i < 65536; ++i)
                noiseTable[i] = -std::log(-std::log(double(i) / 65536.0));
        }
    }
    Plan rollout(const Plan* base, int prefix) {
        Board board = initial;
        Plan result;
        bool destroy = searchMode == 2 && base && uniform(random) < 0.45;
        if (base && !destroy) {
            for (int i = 0; i < prefix; ++i) {
                board.apply(base->moves[i]);
                result.moves.push_back(base->moves[i]);
                result.score += base->moves[i].count;
            }
        }
        if (destroy) {
            // Free a small set of earlier groups while preserving independent
            // work elsewhere, so stranded digits can be regrouped near the end.
            std::vector<bool> suppressed(base->moves.size(), false), used(base->moves.size(), false);
            int deleted = 2 + int(uniform(random) * 7);
            for (int i = 0; i < deleted; ++i) suppressed[size_t(uniform(random) * base->moves.size())] = true;
            bool changed;
            do {
                changed = false;
                for (size_t i = 0; i < base->moves.size(); ++i) {
                    Move retained;
                    if (!suppressed[i] && !used[i] && board.repairMove(base->moves[i], retained)) {
                        board.apply(retained);
                        result.moves.push_back(retained);
                        result.score += retained.count;
                        used[i] = true;
                        changed = true;
                    }
                }
            } while (changed);
        }
        // Preserve scarce small digits for their large complements. Explore
        // several strengths of this preference, rather than maximizing immediate points.
        double weight = uniform(random) * 1.6;
        double countWeight = (uniform(random) - 0.25) * 8.0;
        double temperature = 3.0 + 45.0 * uniform(random);
        // Perturb a short section, then retain legal decisions from the parent
        // trajectory. Disjoint eliminations need not be rediscovered randomly.
        int repairAfter = searchMode > 0 && base && !destroy && uniform(random) < 0.7 ? 1 + int(uniform(random) * 4) : -1;
        int divergentMoves = 0;
        bool tailAttempted = false;
        while (true) {
            if (repairAfter >= 0 && divergentMoves == repairAfter) {
                std::vector<bool> used(base->moves.size(), false);
                bool changed;
                do {
                    changed = false;
                    for (int i = prefix; i < int(base->moves.size()); ++i) {
                        Move retained;
                        if (!used[i] && board.repairMove(base->moves[i], retained) && keepsFullClearPossible(board, retained)) {
                            board.apply(retained);
                            result.moves.push_back(retained);
                            result.score += retained.count;
                            used[i] = true;
                            changed = true;
                        }
                    }
                } while (changed);
                repairAfter = -1;
            }
            if ((searchMode == 5 || searchMode == 7) && !tailAttempted && board.rows * board.cols <= 192 && initialCount - result.score <= (searchMode == 7 ? 32 : 24)) {
                tailAttempted = true;
                int nodes = 0;
                auto tail = solveTail(board, nodes);
                for (const auto& move : tail.moves) {
                    board.apply(move);
                    result.moves.push_back(move);
                    result.score += move.count;
                }
                if (tail.exact) break;
            }
            board.moves(actions);
            if (actions.empty()) break;
            int chosen = -1;
            double maximum = -1e100;
            for (int i = 0; i < int(actions.size()); ++i) {
                const auto& a = actions[i];
                double draw = uniform(random), noise;
                if (searchMode >= 4) {
                    double position = draw * 65536.0;
                    size_t index = size_t(position);
                    // Preserve the original random draws and the unbounded-tail
                    // calculation; interpolate only smooth interior intervals.
                    noise = index == 0 || index >= 65535 ? -std::log(-std::log(draw)) :
                        noiseTable[index] + (noiseTable[index + 1] - noiseTable[index]) * (position - double(index));
                } else noise = -std::log(-std::log(draw));
                double score = weight * a.squares + countWeight * a.count + temperature * noise;
                if (score > maximum && keepsFullClearPossible(board, a)) { maximum = score; chosen = i; }
            }
            if (chosen < 0) break;
            const Move move = actions[chosen];
            board.apply(move);
            result.moves.push_back(move);
            result.score += move.count;
            ++divergentMoves;
        }
        result.signature = 1469598103934665603ULL;
        for (int i = 0; i < board.rows * board.cols; ++i) {
            result.signature ^= board.cells[i];
            result.signature *= 1099511628211ULL;
        }
        return result;
    }
    void step() {
        if (tails.size() > 100000) tails.clear();
        const Plan* base = nullptr;
        int prefix = 0;
        double source = uniform(random);
        if (!elite.empty() && source > 0.25) {
            // Mutate an elite trajectory, including early decisions. Keep fresh
            // independent restarts so the search can leave a local optimum.
            size_t index = size_t(std::pow(uniform(random), 2) * elite.size());
            base = &elite[std::min(index, elite.size() - 1)];
            if (source > 0.8 && !walker.moves.empty()) base = &walker;
            prefix = int(uniform(random) * base->moves.size());
        }
        auto candidate = rollout(base, prefix);
        ++trials;
        if (candidate.score > best.score) best = candidate;
        double temperature = 1.0 + 3.0 * (1.0 - double(trials % 4000) / 4000.0);
        if (walker.moves.empty() || candidate.score >= walker.score || uniform(random) < std::exp((candidate.score - walker.score) / temperature)) walker = candidate;
        bool duplicate = std::any_of(elite.begin(), elite.end(), [&](const Plan& p) { return p.signature == candidate.signature; });
        if (!duplicate && (elite.size() < 64 || candidate.score >= elite.back().score)) {
            elite.push_back(std::move(candidate));
            std::stable_sort(elite.begin(), elite.end(), [](const Plan& a, const Plan& b) { return a.score > b.score; });
            if (elite.size() > 64) elite.resize(64);
        }
    }
};
int main(int argc, char** argv) {
    try {
        double seconds = 32;
        int target = 140, maxTrials = 0;
        uint64_t seed = 1;
        bool listOnly = false;
        bool fullSearch = false;
        std::string path;
        std::string strategy = "portfolio8";
        for (int i = 1; i < argc; ++i) {
            std::string flag = argv[i];
            if (flag == "--moves") { listOnly = true; continue; }
            if (flag == "--full-search") { fullSearch = true; continue; }
            if (i + 1 >= argc) throw std::runtime_error("Missing argument value");
            std::string value = argv[++i];
            if (flag == "--board") path = value;
            else if (flag == "--seconds") seconds = std::stod(value);
            else if (flag == "--target") target = std::stoi(value);
            else if (flag == "--seed") seed = std::stoull(value);
            else if (flag == "--trials") maxTrials = std::stoi(value);
            else if (flag == "--strategy") strategy = value;
            else throw std::runtime_error("Unknown option: " + flag);
        }
        if (path.empty() || !std::isfinite(seconds) || seconds <= 0 || seconds > 60 || maxTrials < 0) throw std::runtime_error("Invalid search arguments: search budget must be greater than zero and at most 60 seconds");
        if (strategy != "baseline" && strategy != "repair" && strategy != "neighborhood" && strategy != "fastrepair" && strategy != "tailrepair" && strategy != "portfolio" && strategy != "portfolio8" && strategy != "perfect8") throw std::runtime_error("Unknown search strategy");
        std::ifstream file(path);
        Board board;
        if (!(file >> board.rows >> board.cols) || board.rows < 1 || board.rows > 30 || board.cols < 1 || board.cols > 30) throw std::runtime_error("Invalid board dimensions");
        for (int i = 0; i < board.rows * board.cols; ++i) {
            int value;
            if (!(file >> value) || value < 0 || value > 9) throw std::runtime_error("Invalid board cell");
            board.cells[i] = uint8_t(value);
        }
        std::string extra;
        if (file >> extra) throw std::runtime_error("Extra board data");
        const auto start = std::chrono::steady_clock::now();
        const int requestedWorkers = (strategy == "portfolio8" || strategy == "perfect8") ? 8 : strategy == "portfolio" ? 4 : 1;
        const int workers = !listOnly ? std::min(requestedWorkers, std::max(1, int(std::thread::hardware_concurrency()))) : 1;
        // All workers share one wall-clock deadline. Reserve a small margin for
        // joining workers and freeing their caches before returning the plan.
        const double computeSeconds = workers > 1 ? std::max(0.001, seconds - 0.05) : seconds;
        const int initialCount = board.count();
        int digitSum = 0;
        for (int i = 0; i < board.rows * board.cols; ++i) digitSum += board.cells[i];
        // Every move removes digit sum ten. A nonzero remainder makes clearing
        // every tile impossible, so leaving one tile is already optimal.
        const int scoreUpperBound = initialCount - (digitSum % 10 != 0 ? 1 : 0);
        std::atomic<bool> optimumFound{false};
        const bool fullClearEligible = board.fullClearPossible();
        struct WorkerResult { Plan plan; int trials; uint64_t seed; };
        auto runWorker = [&](int index) -> WorkerResult {
            uint64_t workerSeed = seed + uint64_t(index) * 0x9e3779b97f4a7c15ULL;
            int mode = (strategy == "portfolio" || strategy == "portfolio8" || strategy == "perfect8") ? (index % 4 < 2 ? 4 : 5) :
                strategy == "tailrepair" ? 5 : strategy == "fastrepair" ? 4 : strategy == "neighborhood" ? 2 : strategy == "repair" ? 1 : 0;
            if (strategy == "perfect8" && fullClearEligible && index >= 6) mode = index == 6 ? 6 : 7;
            double remaining = computeSeconds - std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            if (remaining <= 0) return {{}, 0, workerSeed};
            Search search(board, workerSeed, mode, remaining);
            do {
                search.step();
                if (search.best.score == scoreUpperBound) optimumFound.store(true, std::memory_order_relaxed);
                double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
                if ((maxTrials > 0 && search.trials >= maxTrials) || elapsed >= computeSeconds ||
                    (!fullSearch && search.best.score >= target) || optimumFound.load(std::memory_order_relaxed)) break;
            } while (true);
            return {std::move(search.best), search.trials, workerSeed};
        };
        std::vector<WorkerResult> results;
        if (listOnly) {
            results.push_back({{}, 0, seed});
            board.moves(results[0].plan.moves);
        } else if (workers == 1) results.push_back(runWorker(0));
        else {
            std::vector<std::future<WorkerResult>> pending;
            for (int i = 0; i < workers; ++i) pending.push_back(std::async(std::launch::async, runWorker, i));
            for (auto& worker : pending) results.push_back(worker.get());
        }
        int winner = 0, trials = 0;
        for (int i = 0; i < int(results.size()); ++i) {
            trials += results[i].trials;
            if (results[i].plan.score > results[winner].plan.score ||
                (results[i].plan.score == results[winner].plan.score && results[i].plan.moves.size() < results[winner].plan.moves.size())) winner = i;
        }
        const Plan& best = results[winner].plan;
        // Independently replay the winning path before returning it to automation.
        if (!listOnly) {
            Board verification = board;
            for (const auto& move : best.moves) verification.apply(move);
            if (board.count() - verification.count() != best.score) throw std::runtime_error("Plan score validation failed");
        }
        double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cout << "{\"strategy\":\"" << strategy << "\",\"score\":" << best.score << ",\"trials\":" << trials << ",\"seconds\":" << elapsed << ",\"seed\":" << seed
                  << ",\"scoreUpperBound\":" << scoreUpperBound << ",\"provenOptimal\":" << (!listOnly && best.score == scoreUpperBound ? "true" : "false")
                  << ",\"fullClearEligible\":" << (fullClearEligible ? "true" : "false")
                  << ",\"workers\":" << workers << ",\"winningWorker\":" << winner << ",\"winningSeed\":\"" << results[winner].seed << "\",\"workerScores\":[";
        for (int i = 0; i < int(results.size()); ++i) { if (i) std::cout << ','; std::cout << results[i].plan.score; }
        std::cout << "],\"moves\":[";
        for (size_t i = 0; i < best.moves.size(); ++i) {
            const auto& m = best.moves[i];
            if (i) std::cout << ',';
            std::cout << "{\"top\":" << m.top << ",\"left\":" << m.left << ",\"bottom\":" << m.bottom << ",\"right\":" << m.right << ",\"count\":" << m.count << '}';
        }
        std::cout << "]}\n";
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
