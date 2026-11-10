#define main solver_program_main
#include "../src/Solver.cpp"
#undef main
#include <cassert>

using Counts = std::array<int, 10>;
std::vector<Counts> patterns;
void patternsFor(int value, int remaining, Counts& c) {
    if (value == 0) { if (remaining == 0) patterns.push_back(c); return; }
    for (int k = 0; k * value <= remaining; ++k) {
        c[value] = k;
        patternsFor(value - 1, remaining - k * value, c);
    }
    c[value] = 0;
}
std::unordered_map<std::string, bool> memo;
bool partitionable(const Counts& c) {
    int largest = 9;
    while (largest && !c[largest]) --largest;
    if (!largest) return true;
    std::string key;
    for (int v = 1; v <= 9; ++v) key.push_back(char(c[v]));
    auto cached = memo.find(key);
    if (cached != memo.end()) return cached->second;
    for (const auto& pattern : patterns) {
        if (!pattern[largest]) continue;
        Counts next = c;
        bool fits = true;
        for (int v = 1; v <= 9; ++v) { next[v] -= pattern[v]; fits &= next[v] >= 0; }
        if (fits && partitionable(next)) return memo[key] = true;
    }
    return memo[key] = false;
}
Board makeBoard(const Counts& c) {
    Board b; b.rows = 1;
    for (int v = 1; v <= 9; ++v) for (int k = 0; k < c[v]; ++k) b.cells[b.cols++] = v;
    return b;
}
int main() {
    Counts c{}; patternsFor(9, 10, c);
    int clearable = 0;
    for (int encoding = 0; encoding < 19683; ++encoding) {
        int x = encoding;
        for (int v = 1; v <= 9; ++v) { c[v] = x % 3; x /= 3; }
        bool exact = partitionable(c);
        if (exact) { ++clearable; assert(makeBoard(c).fullClearPossible()); }
    }
    std::mt19937_64 rng(20261110);
    for (int trial = 0; trial < 10000; ++trial) {
        c.fill(0);
        for (int group = 0; group < 40; ++group) {
            const auto& pattern = patterns[rng() % patterns.size()];
            for (int v = 1; v <= 9; ++v) c[v] += pattern[v];
        }
        assert(makeBoard(c).fullClearPossible());
    }
    std::cout << "Passed 19683 exhaustive count vectors (" << clearable
              << " clearable), plus 10000 constructed full-clear multisets.\n";
}
