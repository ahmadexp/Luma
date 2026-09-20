#include "FractalCore.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <thread>
#include <vector>

namespace {
struct Scene {
    const char *name, *real, *imag, *span;
    int iterations;
};
const Scene deepJulia {"deep Julia", "-1.768667862837488812627419470",
                       "0.001645580546820209430325900", "1.6e-21", 50000};

struct Viewport {
    MBViewport* value = mb_viewport_create();
    explicit Viewport(const Scene& scene) {
        assert(value);
        assert(mb_viewport_set(value, scene.real, scene.imag, scene.span));
    }
    ~Viewport() { mb_viewport_destroy(value); }
};
struct Control {
    MBRenderControl* value = mb_render_control_create();
    Control() { assert(value); }
    ~Control() { mb_render_control_destroy(value); }
};

bool close(float actual, float expected) {
    return std::isfinite(actual) && ((actual < 0) == (expected < 0)) &&
           std::abs(actual - expected) <= std::max(0.004f, std::abs(expected) * 2e-6f);
}

void checkPoint(const Scene& scene, MBViewport* viewport, int width, int height,
                size_t index, float actual, float& maximumError) {
    const int column = int(index % size_t(width));
    const int row = int(index / size_t(width));
    const double x = (column + 0.5) / width - 0.5;
    const double y = 0.5 - (row + 0.5) / height;
    float expected;
    assert(mb_sample_mpfr(viewport, x, y, double(height) / width, scene.iterations, &expected));
    maximumError = std::max(maximumError, std::abs(actual - expected));
    if (!close(actual, expected)) {
        std::fprintf(stderr, "%s budget=%d [%d,%d] accelerated=%g MPFR=%g error=%g\n",
                     scene.name, scene.iterations, column, row, actual, expected,
                     std::abs(actual - expected));
        std::abort();
    }
}

uint64_t compareGrid(const Scene& scene, int width, int height, bool allDirect = false) {
    Viewport viewport(scene);
    Control accelerated, ordinary;
    mb_render_control_set_acceleration(ordinary.value, 0);
    std::vector<float> actual(size_t(width) * height), expected(actual.size());
    assert(mb_render(viewport.value, width, height, scene.iterations, actual.data(), accelerated.value) == 1);
    assert(mb_render(viewport.value, width, height, scene.iterations, expected.data(), ordinary.value) == 1);
    float maximumError = 0;
    size_t disputed = 0, directChecks = 0;
    uint64_t random = 0xd1b54a32d192ed03ULL;
    std::vector<bool> check(actual.size(), allDirect);
    // Fixed seed makes the MPFR sample selection reproducible across builds.
    for (int sample = 0; sample < 96; ++sample) {
        random ^= random >> 12; random ^= random << 25; random ^= random >> 27;
        check[size_t((random * 2685821657736338717ULL) % actual.size())] = true;
    }
    check[actual.size() / 2] = check[0] = check.back() = true;
    for (size_t index = 0; index < actual.size(); ++index) {
        if (!close(actual[index], expected[index])) {
            // The unaccelerated perturbation path can also accumulate error.
            // Resolve every disagreement against the independent MPFR oracle.
            check[index] = true;
            ++disputed;
            std::fprintf(stderr, "%s disputed [%zu,%zu]: accelerated=%.9g unaccelerated=%.9g\n",
                         scene.name, index % size_t(width), index / size_t(width),
                         actual[index], expected[index]);
        }
        if (check[index]) {
            checkPoint(scene, viewport.value, width, height, index, actual[index], maximumError);
            ++directChecks;
        }
    }
    MBRenderStats stats {}, disabledStats {};
    mb_render_control_get_stats(accelerated.value, &stats);
    mb_render_control_get_stats(ordinary.value, &disabledStats);
    assert(disabledStats.bla_steps == 0 && disabledStats.skipped_iterations == 0);
    assert(disabledStats.series_iterations == 0 && disabledStats.series_pixels == 0);
    assert(stats.skipped_iterations <= uint64_t(width) * height * scene.iterations);
    assert(stats.series_iterations >= 0 && stats.series_iterations <= scene.iterations);
    assert(stats.series_pixels <= uint64_t(width) * height);
    std::printf("%-22s budget=%-6d pixels=%-6zu direct=%-4zu disputed=%-3zu max_error=%.7g BLA=%llu skipped=%llu\n",
                scene.name, scene.iterations, actual.size(), directChecks, disputed, maximumError,
                (unsigned long long) stats.bla_steps, (unsigned long long) stats.skipped_iterations);
    return stats.skipped_iterations;
}

void iterationBoundaries() {
    uint64_t skips = 0;
    // Escape near -2 occurs after roughly log_4(1/span) iterations. These
    // budgets straddle that boundary and powers of two in the skip hierarchy.
    const int budgets[] = {1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65,
                           127, 128, 129, 255, 256, 257, 511, 512, 513,
                           660, 664, 667, 668, 669, 670, 672, 680};
    for (int budget : budgets) {
        Scene scene {"wide cap boundary", "-2", "0", "1e-400", budget};
        skips += compareGrid(scene, 11, 7, true);
    }
    assert(skips > 0);
    for (int budget : {1, 2, 31, 32, 511, 512, 5000, 6368, 6369, 6370, 8191, 8192}) {
        Scene scene = deepJulia;
        scene.name = "series cap boundary";
        scene.iterations = budget;
        compareGrid(scene, 11, 7, true);
    }
}

void referenceReuse() {
    Viewport viewport(deepJulia);
    Control control;
    std::vector<float> small(32 * 24), large(64 * 48);
    assert(mb_render(viewport.value, 32, 24, 10000, small.data(), control.value) == 1);
    MBRenderStats stats {};
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.reference_reused == 0);
    assert(stats.series_iterations > 5000 && stats.series_pixels == small.size());
    assert(mb_render(viewport.value, 64, 48, 10000, large.data(), control.value) == 1);
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.reference_reused == 1);
    Scene scene = deepJulia;
    scene.iterations = 10000;
    float maximumError = 0;
    for (size_t index : {size_t(0), large.size() / 2, large.size() - 1})
        checkPoint(scene, viewport.value, 64, 48, index, large[index], maximumError);
    // A different iteration budget and camera must invalidate the cache.
    assert(mb_render(viewport.value, 64, 48, 10001, large.data(), control.value) == 1);
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.reference_reused == 0);
    mb_viewport_pan(viewport.value, 0.2, -0.1, 0.75);
    assert(mb_render(viewport.value, 64, 48, 10001, large.data(), control.value) == 1);
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.reference_reused == 0);
    std::puts("Reference reuse and invalidation: passed");
}

void cancellationDuringPreparation() {
    const Scene scene {"cancellation", "-2", "0", "1e-10000", 1000000};
    Viewport viewport(scene);
    Control control;
    std::vector<float> output(128 * 80);
    int result = -2;
    std::thread rendering([&] {
        result = mb_render(viewport.value, 128, 80, scene.iterations, output.data(), control.value);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    const auto start = std::chrono::steady_clock::now();
    mb_render_control_cancel(control.value);
    rendering.join();
    const double latency = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    assert(result == 0);
    assert(latency < 2.0);
    assert(mb_render(viewport.value, 128, 80, 100, output.data(), control.value) == 0);
    std::printf("Cancellation during high precision reference preparation: %.4f s\n", latency);
}

void cancellationDuringPixels() {
    Viewport viewport(deepJulia);
    Control control;
    std::vector<float> preview(32 * 24), output(2048 * 1536);
    assert(mb_render(viewport.value, 32, 24, deepJulia.iterations, preview.data(), control.value) == 1);
    int result = -2;
    std::thread rendering([&] {
        result = mb_render(viewport.value, 2048, 1536, deepJulia.iterations, output.data(), control.value);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    const auto start = std::chrono::steady_clock::now();
    mb_render_control_cancel(control.value);
    rendering.join();
    const double latency = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    assert(result == 0);
    assert(latency < 2.0);
    MBRenderStats stats {};
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.reference_reused == 1);
    std::printf("Cancellation during cached pixel rendering: %.4f s\n", latency);
}
}

int main() {
    compareGrid({"overview dense", "-0.5", "0", "3.5", 900}, 160, 100);
    compareGrid({"seahorse dense", "-0.7435", "0.1314", "0.006", 900}, 160, 100);
    compareGrid({"spiral dense", "-0.743643887037151", "0.131825904205330", "0.000025", 1500}, 160, 100);
    compareGrid({"elephant dense", "0.273", "0.008", "0.008", 900}, 160, 100);
    assert(compareGrid(deepJulia, 160, 100) > 0);
    compareGrid({"series e100", "-2", "0", "1e-100", 1000}, 25, 17, true);
    compareGrid({"series lower threshold", "-2", "0", "1e-119", 1000}, 25, 17, true);
    compareGrid({"below series range", "-2", "0", "1e-121", 1000}, 25, 17, true);
    assert(compareGrid({"wide e400 dense", "-2", "0", "1e-400", 2200}, 64, 40) > 0);
    assert(compareGrid({"wide e1000 dense", "-2", "0", "1e-1000", 4000}, 64, 40) > 0);
    compareGrid({"large coordinates", "1e400", "-1e400", "1e400", 100}, 11, 7, true);
    compareGrid({"cardioid boundary", "0.25000000000001", "0", "1e-12", 1000}, 25, 17, true);
    compareGrid({"bulb boundary", "-1.25000000000001", "0", "1e-12", 1000}, 25, 17, true);
    iterationBoundaries();
    referenceReuse();
#ifndef MB_SINGLE_THREADED
    // Single-threaded hosts cancel by terminating the owning worker.
    cancellationDuringPreparation();
    cancellationDuringPixels();
#endif
    std::puts("All acceleration checks passed.");
}
