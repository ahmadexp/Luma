#include "FractalCore.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
struct Scene {
    const char *name, *real, *imag, *span;
    int iterations;
};
const Scene scenes[] = {
    {"overview", "-0.5", "0", "3.5", 900},
    {"seahorse", "-0.7435", "0.1314", "0.006", 900},
    {"spiral", "-0.743643887037151", "0.131825904205330", "0.000025", 1500},
    {"elephant", "0.273", "0.008", "0.008", 900},
    {"deep_julia", "-1.768667862837488812627419470", "0.001645580546820209430325900", "1.6e-21", 50000},
    {"wide_e400", "-2", "0", "1e-400", 4000},
    {"wide_e1000", "-2", "0", "1e-1000", 4000},
};

uint64_t checksum(const std::vector<float>& values) {
    uint64_t hash = 14695981039346656037ULL;
    for (float value : values) {
        uint32_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        for (int byte = 0; byte < 4; ++byte) {
            hash ^= (bits >> (byte * 8)) & 255;
            hash *= 1099511628211ULL;
        }
    }
    return hash;
}
void fail(const char* message) {
    std::fprintf(stderr, "%s\n", message);
    std::exit(1);
}

bool selected(const Scene& scene, const std::string& selection) {
    const bool wide = std::strncmp(scene.name, "wide_", 5) == 0;
    return selection == "all" || selection == scene.name ||
           (selection == "presets" && !wide) || (selection == "wide" && wide);
}

std::vector<float> readOutput(const std::string& directory, const std::string& name, size_t size) {
    const std::string path = directory + "/" + name + ".f32";
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file) fail("Cannot read benchmark output for comparison");
    std::vector<float> result(size);
    if (std::fread(result.data(), sizeof(float), size, file) != size || std::fgetc(file) != EOF)
        fail("Benchmark output has the wrong size");
    std::fclose(file);
    return result;
}

bool accurate(float actual, float expected) {
    return std::isfinite(actual) && ((actual < 0) == (expected < 0)) &&
           std::abs(actual - expected) <= std::max(0.004f, std::abs(expected) * 2e-6f);
}

void compareOutputs(const std::string& beforeDirectory, const std::string& afterDirectory,
                    int width, int height, const std::string& selection) {
    std::puts("scene,width,height,pixels,bitwise_changed,classification_changed,disputed,baseline_mpfr_failures,optimized_mpfr_failures,regressions,improvements,max_delta");
    for (const Scene& scene : scenes) {
        if (!selected(scene, selection)) continue;
        const std::string name = std::string(scene.name) + "_" + std::to_string(width) + "x" + std::to_string(height);
        const auto before = readOutput(beforeDirectory, name, size_t(width) * height);
        const auto after = readOutput(afterDirectory, name, before.size());
        MBViewport* viewport = mb_viewport_create();
        if (!viewport || !mb_viewport_set(viewport, scene.real, scene.imag, scene.span)) fail("Cannot initialize comparison scene");
        const std::string oraclePath = afterDirectory + "/" + name + ".oracle.csv";
        FILE* oracle = std::fopen(oraclePath.c_str(), "w");
        if (!oracle) fail("Cannot write MPFR comparison report");
        std::fprintf(oracle, "index,column,row,baseline,optimized,mpfr,baseline_error,optimized_error,tolerance\n");
        size_t changed = 0, classifications = 0, disputed = 0;
        size_t beforeBad = 0, afterBad = 0, regressions = 0, improvements = 0;
        float maximumDelta = 0;
        for (size_t index = 0; index < before.size(); ++index) {
            if (before[index] != after[index]) ++changed;
            if ((before[index] < 0) != (after[index] < 0)) ++classifications;
            maximumDelta = std::max(maximumDelta, std::abs(before[index] - after[index]));
            if (accurate(after[index], before[index])) continue;
            ++disputed;
            const int column = int(index % size_t(width));
            const int row = int(index / size_t(width));
            float expected;
            if (!mb_sample_mpfr(viewport, (column + 0.5) / width - 0.5,
                                0.5 - (row + 0.5) / height, double(height) / width,
                                scene.iterations, &expected)) fail("MPFR comparison failed");
            const bool a = accurate(before[index], expected), b = accurate(after[index], expected);
            beforeBad += !a; afterBad += !b;
            regressions += a && !b; improvements += !a && b;
            std::fprintf(oracle, "%zu,%d,%d,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g\n", index, column, row,
                         before[index], after[index], expected, std::abs(before[index] - expected),
                         std::abs(after[index] - expected), std::max(0.004f, std::abs(expected) * 2e-6f));
        }
        std::fclose(oracle);
        std::printf("%s,%d,%d,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%.9g\n", scene.name, width, height,
                    before.size(), changed, classifications, disputed, beforeBad, afterBad,
                    regressions, improvements, maximumDelta);
        mb_viewport_destroy(viewport);
    }
}
}

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "--compare") == 0) {
        if (argc != 7) fail("Usage: benchmark --compare before-directory after-directory width height selection");
        const int width = std::atoi(argv[4]), height = std::atoi(argv[5]);
        if (width < 1 || height < 1) fail("Invalid comparison dimensions");
        compareOutputs(argv[2], argv[3], width, height, argv[6]);
        return 0;
    }
    // Benchmark each binary separately while the app is idle. A fresh control
    // makes every measured render cold, including its reference preparation.
    const int width = argc > 1 ? std::atoi(argv[1]) : 800;
    const int height = argc > 2 ? std::atoi(argv[2]) : 600;
    const int repetitions = argc > 3 ? std::atoi(argv[3]) : 3;
    const std::string selection = argc > 4 ? argv[4] : "presets";
    const std::string dumpDirectory = argc > 5 ? argv[5] : "";
    if (width < 1 || height < 1 || repetitions < 1) fail("Invalid benchmark dimensions or repetitions");
    std::puts("scene,width,height,iterations,median_ms,min_ms,max_ms,escaped,interior,escape_sum,raw_fnv1a,precision_bits,fallback_pixels,rebases,bla_steps,skipped_iterations,series_iterations,series_pixels");
    for (const Scene& scene : scenes) {
        if (!selected(scene, selection)) continue;
        MBViewport* viewport = mb_viewport_create();
        if (!viewport || !mb_viewport_set(viewport, scene.real, scene.imag, scene.span)) fail("Cannot initialize scene");
        std::vector<float> output(size_t(width) * height);
        std::vector<double> durations;
        MBRenderStats stats {};
        uint64_t initialChecksum = 0;
        for (int run = -1; run < repetitions; ++run) {
            MBRenderControl* control = mb_render_control_create();
            if (!control) fail("Cannot allocate render control");
            const auto start = std::chrono::steady_clock::now();
            const int result = mb_render(viewport, width, height, scene.iterations, output.data(), control);
            const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            if (result != 1) fail("Render failed");
            mb_render_control_get_stats(control, &stats);
            mb_render_control_destroy(control);
            const uint64_t hash = checksum(output);
            if (run == -1) initialChecksum = hash;
            else {
                if (hash != initialChecksum) fail("Repeated render output was not deterministic");
                durations.push_back(elapsed);
            }
            std::fprintf(stderr, "%s %dx%d %s %d: %.3f ms\n", scene.name, width, height,
                         run < 0 ? "warmup" : "sample", run < 0 ? 0 : run + 1, elapsed);
            std::fflush(stderr);
        }
        size_t escaped = 0;
        double sum = 0;
        for (float value : output) if (value >= 0) { ++escaped; sum += value; }
        std::sort(durations.begin(), durations.end());
        const double median = (durations[(durations.size() - 1) / 2] + durations[durations.size() / 2]) * 0.5;
        uint64_t blaSteps = 0, skippedIterations = 0;
        int seriesIterations = 0;
        uint64_t seriesPixels = 0;
#ifdef MB_BENCH_ACCELERATION
        blaSteps = stats.bla_steps;
        skippedIterations = stats.skipped_iterations;
        seriesIterations = stats.series_iterations;
        seriesPixels = stats.series_pixels;
#endif
        std::printf("%s,%d,%d,%d,%.6f,%.6f,%.6f,%zu,%zu,%.9f,%016llx,%d,%llu,%llu,%llu,%llu,%d,%llu\n",
                    scene.name, width, height, scene.iterations, median, durations.front(), durations.back(),
                    escaped, output.size() - escaped, sum, (unsigned long long) initialChecksum,
                    stats.precision_bits, (unsigned long long) stats.fallback_pixels,
                    (unsigned long long) stats.rebases, (unsigned long long) blaSteps,
                    (unsigned long long) skippedIterations, seriesIterations,
                    (unsigned long long) seriesPixels);
        std::fflush(stdout);
        if (!dumpDirectory.empty()) {
            const std::string path = dumpDirectory + "/" + scene.name + "_" + std::to_string(width) + "x" + std::to_string(height) + ".f32";
            FILE* file = std::fopen(path.c_str(), "wb");
            if (!file) fail("Cannot open output dump");
            if (std::fwrite(output.data(), sizeof(float), output.size(), file) != output.size()) fail("Cannot write output dump");
            std::fclose(file);
        }
        mb_viewport_destroy(viewport);
    }
}
