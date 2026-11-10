// Full-clear beam search. Retain several distinct boards at each sum-ten depth;
// independent random restarts vary the priority of immediate pair mobility.
#include <unordered_set>

static Plan searchFullClearBeam(const Board& initial, uint64_t seed, double seconds,
                               int& passes, std::atomic<bool>& optimumFound) {
    using Key = std::array<uint64_t, 3>;
    struct Hash {
        size_t operator()(const Key& k) const {
            return size_t(k[0] * 0x9e3779b97f4a7c15ULL ^ k[1] * 0xbf58476d1ce4e5b9ULL ^ k[2]);
        }
    };
    struct History { int parent; Move move; };
    struct Node { Board board; int parent = -1, trail = -1; Move move{}; double rank = 0; };
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds));
    auto expired = [&] { return optimumFound.load(std::memory_order_relaxed) || std::chrono::steady_clock::now() >= deadline; };
    std::mt19937_64 random(seed);
    std::uniform_real_distribution<double> uniform(0.000001, 0.999999);
    const int initialCount = initial.count();
    Plan best;
    while (!expired()) {
        ++passes;
        const size_t width = passes % 3 == 0 ? 128 : 64;
        const double temperature = 1 + 14 * uniform(random), countWeight = 5 * uniform(random);
        std::vector<History> history;
        std::vector<Node> beam(1);
        beam[0].board = initial;
        while (!beam.empty() && !expired()) {
            std::vector<Node> next;
            std::unordered_set<Key, Hash> seen;
            for (const auto& parent : beam) {
                if (expired()) return best;
                std::vector<Move> moves;
                parent.board.moves(moves);
                for (const auto& move : moves) {
                    Node child;
                    child.board = parent.board;
                    child.board.apply(move);
                    if (!child.board.fullClearPossible()) continue;
                    Key key{};
                    for (int i = 0; i < initial.rows * initial.cols; ++i)
                        if (child.board.cells[i]) key[i / 64] |= uint64_t(1) << (i % 64);
                    if (!seen.insert(key).second) continue;
                    child.parent = parent.trail; child.move = move;
                    const int score = initialCount - child.board.count();
                    if (score > best.score) {
                        best.score = score;
                        best.moves = {move};
                        for (int p = child.parent; p >= 0; p = history[p].parent) best.moves.push_back(history[p].move);
                        std::reverse(best.moves.begin(), best.moves.end());
                        if (score == initialCount) {
                            optimumFound.store(true, std::memory_order_relaxed);
                            return best;
                        }
                    }
                    int pairs = 0;
                    for (int r = 0; r < initial.rows; ++r) {
                        int previous = 0;
                        for (int c = 0; c < initial.cols; ++c) {
                            int v = child.board.cells[r * initial.cols + c];
                            if (v) { pairs += previous + v == 10; previous = v; }
                        }
                    }
                    for (int c = 0; c < initial.cols; ++c) {
                        int previous = 0;
                        for (int r = 0; r < initial.rows; ++r) {
                            int v = child.board.cells[r * initial.cols + c];
                            if (v) { pairs += previous + v == 10; previous = v; }
                        }
                    }
                    child.rank = 3 * pairs + countWeight * score - temperature * std::log(-std::log(uniform(random)));
                    next.push_back(std::move(child));
                }
            }
            if (next.size() > width * 4) {
                std::nth_element(next.begin(), next.begin() + width * 4, next.end(),
                                 [](const Node& a, const Node& b) { return a.rank > b.rank; });
                next.resize(width * 4);
            }
            for (auto& child : next) {
                if (expired()) return best;
                std::vector<Move> legal;
                child.board.moves(legal);
                std::array<bool, 192> covered{};
                for (const auto& move : legal)
                    for (int r = move.top; r <= move.bottom; ++r)
                        for (int c = move.left; c <= move.right; ++c)
                            if (child.board.cells[r * initial.cols + c]) covered[r * initial.cols + c] = true;
                int isolated = 0;
                for (int i = 0; i < initial.rows * initial.cols; ++i) isolated += child.board.cells[i] && !covered[i];
                child.rank = 0.2 * child.rank - 4 * isolated + 0.15 * legal.size();
            }
            if (next.size() > width) {
                std::nth_element(next.begin(), next.begin() + width, next.end(),
                                 [](const Node& a, const Node& b) { return a.rank > b.rank; });
                next.resize(width);
            }
            for (auto& child : next) {
                child.trail = int(history.size());
                history.push_back({child.parent, child.move});
            }
            beam = std::move(next);
        }
    }
    return best;
}
