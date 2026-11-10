#define main solver_program_main
#include "../../../../Solver.cpp"
#undef main
#include <cassert>
int main() {
    int complete = 0;
    for (int seed = 1; seed <= 10; ++seed) {
        Board b; b.rows = 2; b.cols = 4;
        int digits[] = {1,9,2,8,3,7,4,6};
        for (int i = 0; i < 8; ++i) b.cells[i] = digits[i];
        std::atomic<bool> found{false}; int passes = 0;
        Plan plan = searchFullClearBeam(b, seed, 0.5, passes, found);
        Board after = b;
        for (const auto& move : plan.moves) after.apply(move);
        assert(b.count() - after.count() == plan.score);
        assert(plan.score == 8 && found.load());
        ++complete;
    }
    std::cout << "Beam direct checks: " << complete << " full clears, independently replayed.\n";
}
