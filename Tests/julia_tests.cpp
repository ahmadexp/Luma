#include "FractalCore.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <thread>
#include <vector>

namespace {
struct Camera {
    MBViewport* value = mb_viewport_create();
    Camera(const char* real, const char* imag, const char* span) {
        assert(value && mb_viewport_set(value, real, imag, span));
    }
    ~Camera() { mb_viewport_destroy(value); }
};
struct Control {
    MBRenderControl* value = mb_render_control_create();
    Control() { assert(value); }
    ~Control() { mb_render_control_destroy(value); }
};

void compare(const char* name, const char* real, const char* imag, const char* span,
             const char* cr, const char* ci, int width, int height, int maximum,
             bool expectWide = false) {
    Camera camera(real, imag, span);
    Control control;
    std::vector<float> result(size_t(width) * height);
    assert(mb_render_control_progress(control.value) == 0);
    assert(mb_render_julia(camera.value, cr, ci, width, height, maximum,
                           result.data(), control.value) == 1);
    assert(mb_render_control_progress(control.value) == 1);
    float maxError = 0;
    int escaped = 0;
    for (int row = 0; row < height; ++row) {
        const double y = 0.5 - (row + 0.5) / height;
        for (int column = 0; column < width; ++column) {
            const double x = (column + 0.5) / width - 0.5;
            float expected;
            assert(mb_sample_julia_mpfr(camera.value, cr, ci, x, y, double(height) / width,
                                        maximum, &expected));
            const float actual = result[size_t(row) * width + column];
            const float error = std::abs(actual - expected);
            maxError = std::max(maxError, error);
            if (!std::isfinite(actual) || (actual < 0) != (expected < 0)
                || error > std::max(0.004f, std::abs(expected) * 2e-6f)) {
                std::fprintf(stderr, "%s [%d,%d] actual=%g MPFR=%g error=%g\n",
                             name, column, row, actual, expected, error);
                std::abort();
            }
            escaped += actual >= 0;
        }
    }
    MBRenderStats stats {};
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.wide_exponent == int(expectWide));
    assert(stats.bla_steps == 0 && stats.skipped_iterations == 0 && stats.series_pixels == 0);
    assert(stats.precision_bits >= mb_viewport_precision(camera.value));
    std::printf("Julia %-23s %dx%d %d iterations, escaped=%d, max_error=%g, fallback=%llu, %.2fms\n",
                name, width, height, maximum, escaped, maxError,
                (unsigned long long) stats.fallback_pixels, stats.elapsed_milliseconds);
}

void validation() {
    Camera camera("0", "0", "3.5");
    Control control;
    float pixel;
    for (const char* invalid : {"", "hello", "nan", "inf"}) {
        assert(mb_render_julia(camera.value, invalid, "0", 1, 1, 100, &pixel, control.value) == -1);
        assert(mb_sample_julia_mpfr(camera.value, "0", invalid, 0, 0, 1, 100, &pixel) == 0);
    }
    assert(mb_render_julia(camera.value, nullptr, "0", 1, 1, 100, &pixel, control.value) == -1);
    assert(mb_render_julia(camera.value, "0", "0", 0, 1, 100, &pixel, control.value) == -1);
    assert(mb_render_julia(camera.value, "0", "0", 1, 1, 0, &pixel, control.value) == -1);
    assert(mb_render_julia(nullptr, "0", "0", 1, 1, 100, &pixel, control.value) == -1);
    assert(mb_sample_julia_mpfr(camera.value, "0", "0", 0, 0, -1, 100, &pixel) == 0);
    assert(mb_render_control_progress(nullptr) == 0);
    mb_render_control_cancel(control.value);
    assert(mb_render_julia(camera.value, "0", "0", 1, 1, 100, &pixel, control.value) == 0);
}

std::string describe(MBViewport* viewport) {
    char* text = mb_viewport_describe(viewport);
    assert(text);
    std::string result(text);
    mb_string_free(text);
    return result;
}

std::string coordinate(const std::string& json, const char* name) {
    const std::string key = std::string("\"") + name + "\":\"";
    const auto begin = json.find(key) + key.size();
    const auto end = json.find('"', begin);
    assert(begin >= key.size() && end != std::string::npos);
    return json.substr(begin, end - begin);
}

void stableCameraRestore() {
    Camera original("-0.5", "0", "3.5");
    mb_viewport_zoom(original.value, std::ldexp(1.0, -101), 0.125, -0.25, 0.75);
    const int bits = mb_viewport_precision(original.value);
    assert(bits == 195);
    const auto expected = describe(original.value);
    Camera restored("0", "0", "3.5");
    auto serialized = expected;
    for (int iteration = 0; iteration < 25; ++iteration) {
        const auto real = coordinate(serialized, "real");
        const auto imag = coordinate(serialized, "imag");
        const auto span = coordinate(serialized, "span");
        assert(mb_viewport_restore(restored.value, real.c_str(), imag.c_str(), span.c_str(), bits));
        assert(mb_viewport_precision(restored.value) == bits);
        serialized = describe(restored.value);
        assert(serialized == expected);
    }
    for (int invalid : {-1, 0, 127, std::numeric_limits<int>::max()}) {
        assert(!mb_viewport_restore(restored.value, "0", "0", "1", invalid));
        assert(describe(restored.value) == expected);
    }
    for (const char* invalid : {"", "nan", "inf", "invalid"}) {
        assert(!mb_viewport_restore(restored.value, invalid, "0", "1", 195));
        assert(describe(restored.value) == expected);
    }
    assert(!mb_viewport_restore(restored.value, "0", "0", "-1", 195));
    assert(!mb_viewport_restore(restored.value, nullptr, "0", "1", 195));
    assert(!mb_viewport_restore(nullptr, "0", "0", "1", 195));
    assert(describe(restored.value) == expected);
    Camera shortDecimals("0", "0", "3.5");
    mb_viewport_zoom(shortDecimals.value, std::ldexp(1.0, -101), 0, 0, 0.75);
    mb_viewport_zoom(shortDecimals.value, std::ldexp(1.0, 101), 0, 0, 0.75);
    assert(mb_viewport_precision(shortDecimals.value) == 195);
    const auto shortDescription = describe(shortDecimals.value);
    assert(mb_viewport_restore(restored.value, "0", "0", "3.5", 195));
    assert(describe(restored.value) == shortDescription);
    assert(mb_viewport_restore(restored.value, "1", "0", "1e-1000", 128));
    assert(mb_viewport_precision(restored.value) >= 3400);
    assert(std::abs(mb_viewport_log_zoom(restored.value) - 1000.5440680443503) < 1e-10);
    std::puts("Camera restore: 25 exact round trips at 195 bits; invalid input and depth guard passed");
}

void cancellationAndProgress() {
    Camera camera("0", "0", "2");
    Control control;
    std::vector<float> pixels(640 * 400);
    int result = -2;
    std::thread work([&] {
        result = mb_render_julia(camera.value, "-0.8", "0.156", 640, 400, 1000000,
                                 pixels.data(), control.value);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(15));
    const double progress = mb_render_control_progress(control.value);
    assert(progress >= 0 && progress <= 1);
    const auto start = std::chrono::steady_clock::now();
    mb_render_control_cancel(control.value);
    work.join();
    assert(result == 0);
    const double delay = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    assert(delay < 2);
    std::printf("Julia cancellation: %.5fs, progress %.3f\n", delay, progress);
}

void interactivePreview() {
    Camera camera("0", "0", "3.5");
    Control control;
    std::vector<float> pixels(640 * 400);
    assert(mb_render_julia(camera.value, "-0.8", "0.156", 640, 400, 900,
                           pixels.data(), control.value) == 1);
    MBRenderStats stats {};
    mb_render_control_get_stats(control.value, &stats);
    assert(stats.elapsed_milliseconds < 5000);
    assert(mb_render_control_progress(control.value) == 1);
    std::printf("Julia 640 x 400 preview: %.2fms\n", stats.elapsed_milliseconds);
}
}

int main() {
    validation();
    stableCameraRestore();
    compare("dendrite", "0", "0", "3.5", "-0.8", "0.156", 64, 41, 900);
    compare("dragon", "0", "0", "3.5", "-0.4", "0.6", 64, 41, 900);
    compare("islands", "0", "0", "3.5", "0.285", "0.01", 64, 41, 900);
    compare("spiral", "0", "0", "3.5", "-0.835", "-0.2321", 64, 41, 900);
    compare("unit circle e24", "1", "0", "1e-24", "0", "0", 13, 9, 200);
    compare("real boundary e100", "2", "0", "1e-100", "-2", "0", 13, 9, 400);
    compare("critical preperiod e200", "0", "0", "1e-200", "-2", "0", 11, 7, 1000, true);
    compare("wide circle e400", "1", "0", "1e-400", "0", "0", 11, 7, 1800, true);
    compare("wide interval e1000", "2", "0", "1e-1000", "-2", "0", 11, 7, 2200, true);
    compare("attracting critical cycle", "0", "0", "1e-400", "-1", "0", 5, 3, 256, true);
    compare("huge parameter", "0", "0", "3.5", "1e400", "-1e400", 7, 5, 10);
    compare("large escape radius", "10000", "0", "1e-400", "-1e8", "0", 5, 3, 20, true);
    const std::string preciseParameter = "-1." + std::string(400, '9');
    compare("precise decimal c", "2", "0", "1e-400", preciseParameter.c_str(), "0", 11, 7, 800, true);
    for (int cap : {1, 2, 31, 32, 63, 64, 127, 128, 255, 256})
        compare("iteration cap", "2", "0", "1e-100", "-2", "0", 5, 3, cap);
#ifndef MB_SINGLE_THREADED
    // Single-threaded hosts cancel by terminating the owning worker.
    cancellationAndProgress();
#endif
    interactivePreview();
    std::puts("All Julia checks passed.");
}
