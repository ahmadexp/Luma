#include "FractalCore.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
void compareGrid(const char* name, const char* real, const char* imag, const char* span,
                 int width, int height, int iterations, bool expectWide) {
    MBViewport* viewport = mb_viewport_create();
    assert(viewport);
    assert(mb_viewport_set(viewport, real, imag, span));
    MBRenderControl* control = mb_render_control_create();
    std::vector<float> output(size_t(width) * height);
    assert(mb_render(viewport, width, height, iterations, output.data(), control) == 1);
    int escaped = 0, interior = 0;
    float maximumError = 0;
    for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
            const double x = (column + 0.5) / width - 0.5;
            const double y = 0.5 - (row + 0.5) / height;
            float direct;
            assert(mb_sample_mpfr(viewport, x, y, double(height) / width, iterations, &direct));
            const float actual = output[size_t(row) * width + column];
            if ((direct < 0) != (actual < 0)) {
                std::fprintf(stderr, "%s [%d,%d]: direct=%g actual=%g\n", name, column, row, direct, actual);
                std::abort();
            }
            if (actual < 0) ++interior; else ++escaped;
            maximumError = std::max(maximumError, std::abs(direct - actual));
            // Float output intentionally gives roughly seven significant digits.
            if (std::abs(direct - actual) > std::max(0.004f, std::abs(direct) * 2e-6f)) {
                std::fprintf(stderr, "%s [%d,%d]: direct=%g actual=%g error=%g\n", name,
                             column, row, direct, actual, std::abs(direct - actual));
                std::abort();
            }
        }
    }
    MBRenderStats stats;
    mb_render_control_get_stats(control, &stats);
    assert(stats.wide_exponent == int(expectWide));
    std::printf("%-22s bits=%d escaped=%d interior=%d max_error=%.6g fallback=%llu rebases=%llu %.1fms\n",
                name, stats.precision_bits, escaped, interior, maximumError,
                (unsigned long long) stats.fallback_pixels, (unsigned long long) stats.rebases,
                stats.elapsed_milliseconds);
    mb_render_control_destroy(control);
    mb_viewport_destroy(viewport);
}

void deepCamera() {
    MBViewport* viewport = mb_viewport_create();
    assert(mb_viewport_set(viewport, "-2", "0", "1e-400"));
    assert(mb_viewport_precision(viewport) > 1400);
    assert(std::abs(mb_viewport_log_zoom(viewport) - 400.5440680443503) < 1e-10);
    char* before = mb_viewport_describe(viewport);
    mb_viewport_pan(viewport, 0.25, -0.125, 0.75);
    char* after = mb_viewport_describe(viewport);
    assert(before && after && std::strcmp(before, after) != 0);
    MBViewport* clone = mb_viewport_clone(viewport);
    char* cloned = mb_viewport_describe(clone);
    assert(std::strcmp(after, cloned) == 0);
    mb_string_free(before);
    mb_string_free(after);
    mb_string_free(cloned);
    mb_viewport_zoom(viewport, 1e-200, 0.2, -0.3, 0.75);
    assert(mb_viewport_precision(viewport) > 2000);
    assert(std::abs(mb_viewport_log_zoom(viewport) - 600.5440680443503) < 1e-10);
    assert(!mb_viewport_set(viewport, "nan", "0", "1"));
    assert(!mb_viewport_set(viewport, "0", "0", "-1"));
    assert(!mb_viewport_set(viewport, "0", "0", "0"));
    assert(!mb_viewport_set(viewport, "garbage", "0", "1"));
    assert(std::abs(mb_viewport_log_zoom(viewport) - 600.5440680443503) < 1e-10);
    mb_viewport_destroy(clone);
    mb_viewport_destroy(viewport);
    std::puts("deep camera precision, pan, anchor zoom, clone, and invalid input: passed");
}

void cancellation() {
    MBViewport* viewport = mb_viewport_create();
    assert(mb_viewport_set(viewport, "-2", "0", "1e-1000"));
    MBRenderControl* control = mb_render_control_create();
    std::vector<float> image(640 * 400);
    int result = -2;
    std::thread rendering([&] { result = mb_render(viewport, 640, 400, 100000,
                                                    image.data(), control); });
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    const auto start = std::chrono::steady_clock::now();
    mb_render_control_cancel(control);
    rendering.join();
    assert(result == 0);
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    assert(seconds < 2);
    assert(mb_render(viewport, 640, 400, 100, image.data(), control) == 0);
    mb_render_control_destroy(control);
    mb_viewport_destroy(viewport);
    std::printf("cancellation: passed (%.4fs response)\n", seconds);
}

void previewBenchmark() {
    MBViewport* viewport = mb_viewport_create();
    MBRenderControl* control = mb_render_control_create();
    std::vector<float> image(640 * 400);
    assert(mb_render(viewport, 640, 400, 600, image.data(), control) == 1);
    MBRenderStats stats;
    mb_render_control_get_stats(control, &stats);
    std::printf("640 x 400 preview, 600 iterations: %.1fms, %llu fallback pixels\n",
                stats.elapsed_milliseconds, (unsigned long long) stats.fallback_pixels);
    mb_render_control_destroy(control);
    mb_viewport_destroy(viewport);
}
}

int main() {
    deepCamera();
    compareGrid("ordinary overview", "-0.5", "0", "3.5", 47, 31, 600, false);
    compareGrid("zoomed out", "0", "0", "350", 19, 13, 100, false);
    compareGrid("large finite span", "0", "0", "1e155", 9, 5, 100, false);
    compareGrid("seahorse valley", "-0.743643887037151", "0.131825904205330",
                "2e-10", 24, 16, 1400, false);
    compareGrid("double beyond e24", "-2", "0", "1e-24", 20, 7, 1000, false);
    compareGrid("wide e280", "-2", "0", "1e-280", 20, 7, 1800, true);
    compareGrid("wide e400", "-2", "0", "1e-400", 20, 7, 2200, true);
    compareGrid("wide e1000", "-2", "0", "1e-1000", 16, 5, 4000, true);
    cancellation();
    previewBenchmark();
    std::puts("All Mandelbrot numerical checks passed.");
}
