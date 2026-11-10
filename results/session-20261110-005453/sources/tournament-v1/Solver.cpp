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
    const Board initial;
    std::mt19937_64 random;
    std::uniform_real_distribution<double> uniform{0.000001, 0.999999};
    std::vector<Move> actions;
    int searchMode;
public:
    int trials = 0;
    Plan best;
    std::vector<Plan> elite;
    Plan walker;
    explicit Search(const Board& board, uint64_t seed, int mode = 0) : initial(board), random(seed), searchMode(mode) { actions.reserve(256); }
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
        while (true) {
            if (repairAfter >= 0 && divergentMoves == repairAfter) {
                std::vector<bool> used(base->moves.size(), false);
                bool changed;
                do {
                    changed = false;
                    for (int i = prefix; i < int(base->moves.size()); ++i) {
                        Move retained;
                        if (!used[i] && board.repairMove(base->moves[i], retained)) {
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
            board.moves(actions);
            if (actions.empty()) break;
            int chosen = 0;
            double maximum = -1e100;
            for (int i = 0; i < int(actions.size()); ++i) {
                const auto& a = actions[i];
                double noise = -std::log(-std::log(uniform(random)));
                double score = weight * a.squares + countWeight * a.count + temperature * noise;
                if (score > maximum) { maximum = score; chosen = i; }
            }
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
        std::string strategy = "baseline";
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
        if (path.empty() || !std::isfinite(seconds) || seconds <= 0 || seconds > 32 || maxTrials < 0) throw std::runtime_error("Invalid search arguments: search budget must be greater than zero and at most 32 seconds");
        if (strategy != "baseline" && strategy != "repair" && strategy != "neighborhood") throw std::runtime_error("Unknown search strategy");
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
        Search search(board, seed, strategy == "neighborhood" ? 2 : strategy == "repair" ? 1 : 0);
        const auto start = std::chrono::steady_clock::now();
        if (listOnly) board.moves(search.best.moves);
        else do {
            search.step();
            double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            if ((maxTrials > 0 && search.trials >= maxTrials) || elapsed >= seconds ||
                (!fullSearch && search.best.score >= target) || search.best.score == board.count()) break;
        } while (true);
        // Independently replay the winning path before returning it to automation.
        if (!listOnly) {
            Board verification = board;
            for (const auto& move : search.best.moves) verification.apply(move);
            if (board.count() - verification.count() != search.best.score) throw std::runtime_error("Plan score validation failed");
        }
        double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::cout << "{\"strategy\":\"" << strategy << "\",\"score\":" << search.best.score << ",\"trials\":" << search.trials << ",\"seconds\":" << elapsed << ",\"seed\":" << seed << ",\"moves\":[";
        for (size_t i = 0; i < search.best.moves.size(); ++i) {
            const auto& m = search.best.moves[i];
            if (i) std::cout << ',';
            std::cout << "{\"top\":" << m.top << ",\"left\":" << m.left << ",\"bottom\":" << m.bottom << ",\"right\":" << m.right << ",\"count\":" << m.count << '}';
        }
        std::cout << "]}\n";
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
