#include "FractalCore.h"

#include <mpfr.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr mpfr_prec_t kMinimumPrecision = 128;
constexpr mpfr_prec_t kGuardBits = 96;
constexpr double kBailoutSquared = 65536.0;
// Restrict each linearized step to |delta| < 1e-17 |2 Z|. This is a
// numerical error tolerance, independent of output resolution and iteration
// budget. Merged radii guarantee it holds at every intermediate step.
constexpr double kBLAEpsilon = 1e-17;
constexpr double kRadiusSafety = 0.9999999999;
constexpr double kLogTwo = 0.693147180559945309417;

void setExponentRange() {
    // MPFR's exponent environment is thread-local in thread-safe builds.
    mpfr_set_emin(MPFR_EMIN_MIN);
    mpfr_set_emax(MPFR_EMAX_MAX);
}

struct Number {
    mpfr_t value;
    explicit Number(mpfr_prec_t bits) { mpfr_init2(value, bits); }
    ~Number() { mpfr_clear(value); }
    Number(const Number&) = delete;
    Number& operator=(const Number&) = delete;
};

// A complex floating-point value with an explicit, shared binary exponent.
// This preserves relative precision when a pixel offset is smaller than 1e-308.
// MPFR retains the absolute camera/reference precision; this type only handles
// the inexpensive perturbations around that high-precision reference.
struct WideComplex {
    double real = 0;
    double imag = 0;
    int64_t exponent = 0;

    static WideComplex normalized(double r, double i, int64_t e = 0) {
        const double maximum = std::max(std::abs(r), std::abs(i));
        if (maximum == 0) return {};
        int shift;
        std::frexp(maximum, &shift);
        return {std::ldexp(r, -shift), std::ldexp(i, -shift), e + shift};
    }
    static WideComplex fromMPFR(mpfr_srcptr r, mpfr_srcptr i) {
        mpfr_exp_t re = 0, ie = 0;
        double rm = mpfr_zero_p(r) ? 0 : mpfr_get_d_2exp(&re, r, MPFR_RNDN);
        double im = mpfr_zero_p(i) ? 0 : mpfr_get_d_2exp(&ie, i, MPFR_RNDN);
        if (!rm && !im) return {};
        if (!rm) return normalized(0, im, ie);
        if (!im) return normalized(rm, 0, re);
        const auto e = std::max(re, ie);
        rm = (e - re > 1074) ? 0 : std::ldexp(rm, int(re - e));
        im = (e - ie > 1074) ? 0 : std::ldexp(im, int(ie - e));
        return normalized(rm, im, e);
    }
    bool zero() const { return real == 0 && imag == 0; }
    double mantissaSquared() const { return real * real + imag * imag; }
    WideComplex operator+(const WideComplex& b) const {
        if (zero()) return b;
        if (b.zero()) return *this;
        if (exponent >= b.exponent) {
            const int64_t difference = exponent - b.exponent;
            if (difference > 56) return *this;
            return normalized(real + std::ldexp(b.real, -int(difference)),
                              imag + std::ldexp(b.imag, -int(difference)), exponent);
        }
        return b + *this;
    }
    WideComplex operator*(const WideComplex& b) const {
        if (zero() || b.zero()) return {};
        return normalized(real * b.real - imag * b.imag,
                          real * b.imag + imag * b.real, exponent + b.exponent);
    }
    WideComplex doubled() const { return {real, imag, exponent + 1}; }
    WideComplex scaled(double scale) const {
        return normalized(real * scale, imag * scale, exponent);
    }
    bool magnitudeLess(const WideComplex& b) const {
        if (zero()) return !b.zero();
        if (b.zero()) return false;
        const int64_t difference = exponent - b.exponent;
        if (difference < -1) return true;
        if (difference > 1) return false;
        return std::ldexp(mantissaSquared(), int(2 * difference)) < b.mantissaSquared();
    }
    bool escaped() const {
        if (zero() || exponent < 8) return false;
        if (exponent > 9) return true;
        return std::ldexp(mantissaSquared(), int(2 * exponent)) > kBailoutSquared;
    }
    double logMagnitude() const {
        return double(exponent) * kLogTwo + 0.5 * std::log(mantissaSquared());
    }
};

struct OrdinaryBLA {
    double ar = 0, ai = 0, br = 0, bi = 0;
    double radius = 0;
};

struct WideBLA {
    WideComplex a, b, radius;
};

constexpr size_t kSeriesDegree = 32;
struct InitialSeries {
    std::array<std::complex<double>, kSeriesDegree + 1> coefficients {};
    double scale = 0;
    double truncationError = 0;
    int iterations = 0;
};

using OrdinaryTable = std::vector<std::vector<OrdinaryBLA>>;
using WideTable = std::vector<std::vector<WideBLA>>;

WideComplex magnitude(const WideComplex& value) {
    return WideComplex::normalized(std::hypot(value.real, value.imag), 0, value.exponent);
}

// These operations are only used for positive real radii while building BLA
// tables. Keep the shared exponent throughout, even beyond 1e-1000 zooms.
WideComplex positiveDifference(const WideComplex& a, const WideComplex& b) {
    if (!b.magnitudeLess(a)) return {};
    if (b.zero() || a.exponent - b.exponent > 56) return a.scaled(kRadiusSafety);
    return WideComplex::normalized(a.real - std::ldexp(b.real, int(b.exponent - a.exponent)),
                                   0, a.exponent).scaled(kRadiusSafety);
}

WideComplex positiveDivide(const WideComplex& a, const WideComplex& b) {
    if (a.zero() || b.zero()) return {};
    return WideComplex::normalized(a.real / b.real, 0, a.exponent - b.exponent);
}

struct ReferencePoint {
    double real;
    double imag;
    WideComplex wide;
};

float smoothEscape(int iteration, double logMagnitude) {
    // Negative output is reserved for the unescaped sentinel. Very distant
    // exterior points can otherwise have a negative smooth iteration count.
    return float(std::max(0.0, double(iteration) + 1.0 - std::log2(logMagnitude)));
}

bool definitelyInterior(double real, double imag) {
    const double y2 = imag * imag;
    const double x = real - 0.25;
    const double q = x * x + y2;
    const double left = q * (q + x);
    const double right = 0.25 * y2;
    // Leave a guard band around both analytic boundaries. Deep coordinates may
    // round to the same double, so a raw <= test could discard exterior pixels.
    if (left < right - 1e-14 * (1 + std::abs(left) + right)) return true;
    const double bulb = (real + 1) * (real + 1) + y2;
    return bulb < 0.0625 - 1e-14;
}
}

struct MBViewport {
    mpfr_t real;
    mpfr_t imag;
    mpfr_t span;
    MBViewport() {
        setExponentRange();
        mpfr_inits2(kMinimumPrecision, real, imag, span, (mpfr_ptr) nullptr);
        mpfr_set_d(real, -0.5, MPFR_RNDN);
        mpfr_set_zero(imag, 1);
        mpfr_set_d(span, 3.5, MPFR_RNDN);
    }
    ~MBViewport() { mpfr_clears(real, imag, span, (mpfr_ptr) nullptr); }
    mpfr_prec_t precision() const { return mpfr_get_prec(real); }
    void raisePrecision(mpfr_prec_t bits) {
        if (bits <= precision()) return;
        mpfr_prec_round(real, bits, MPFR_RNDN);
        mpfr_prec_round(imag, bits, MPFR_RNDN);
        mpfr_prec_round(span, bits, MPFR_RNDN);
    }
};

struct PreparedReference {
    MBViewport camera;
    int maximum = 0;
    double aspectBound = 0;
    std::vector<ReferencePoint> reference;
    OrdinaryTable ordinary;
    WideTable wide;
    InitialSeries series;

    bool matches(const MBViewport& v, int iterations) const {
        return maximum == iterations && camera.precision() == v.precision()
            && mpfr_equal_p(camera.real, v.real) && mpfr_equal_p(camera.imag, v.imag)
            && mpfr_equal_p(camera.span, v.span);
    }
    void snapshot(const MBViewport& v, int iterations) {
        camera.raisePrecision(v.precision());
        mpfr_set(camera.real, v.real, MPFR_RNDN);
        mpfr_set(camera.imag, v.imag, MPFR_RNDN);
        mpfr_set(camera.span, v.span, MPFR_RNDN);
        maximum = iterations;
    }
};

struct MBRenderControl {
    std::atomic<bool> cancelled {false};
    std::atomic<bool> acceleration {true};
    std::atomic<int> completedRows {0};
    std::atomic<int> renderHeight {0};
    std::mutex renderMutex;
    std::unique_ptr<PreparedReference> prepared;
    mutable std::mutex statsMutex;
    MBRenderStats stats {};
};

namespace {
mpfr_prec_t requiredPrecision(mpfr_srcptr real, mpfr_srcptr imag, mpfr_srcptr span) {
    const auto re = mpfr_zero_p(real) ? 0 : mpfr_get_exp(real);
    const auto ie = mpfr_zero_p(imag) ? 0 : mpfr_get_exp(imag);
    const auto se = mpfr_get_exp(span);
    const long double bits = std::max<long double>(0, std::max(re, ie)) - se + kGuardBits;
    if (bits >= static_cast<long double>(MPFR_PREC_MAX)) throw std::bad_alloc();
    return std::max(kMinimumPrecision, mpfr_prec_t(std::max<long double>(2, bits)));
}

bool cancelled(const MBRenderControl* control) {
    return control && control->cancelled.load(std::memory_order_relaxed);
}

struct DirectWorkspace {
    mpfr_t cr, ci, zr, zi, r2, i2, temporary, magnitude;
    explicit DirectWorkspace(mpfr_prec_t precision) {
        mpfr_inits2(precision, cr, ci, zr, zi, r2, i2, temporary, magnitude,
                    (mpfr_ptr) nullptr);
    }
    ~DirectWorkspace() {
        mpfr_clears(cr, ci, zr, zi, r2, i2, temporary, magnitude, (mpfr_ptr) nullptr);
    }
    float evaluateJulia(const MBViewport& viewport, const MBViewport& parameter,
                         mpfr_srcptr bailout, double x, double y, double aspect,
                         int maximum, const MBRenderControl* control = nullptr) {
        mpfr_set(cr, parameter.real, MPFR_RNDN);
        mpfr_set(ci, parameter.imag, MPFR_RNDN);
        mpfr_mul_d(zr, viewport.span, x, MPFR_RNDN);
        mpfr_add(zr, zr, viewport.real, MPFR_RNDN);
        mpfr_mul_d(zi, viewport.span, y * aspect, MPFR_RNDN);
        mpfr_add(zi, zi, viewport.imag, MPFR_RNDN);
        for (int iteration = 1; iteration <= maximum; ++iteration) {
            if ((iteration & 63) == 0 && cancelled(control)) return -1;
            mpfr_sqr(r2, zr, MPFR_RNDN);
            mpfr_sqr(i2, zi, MPFR_RNDN);
            mpfr_mul(temporary, zr, zi, MPFR_RNDN);
            mpfr_mul_2ui(temporary, temporary, 1, MPFR_RNDN);
            mpfr_add(zi, temporary, ci, MPFR_RNDN);
            mpfr_sub(zr, r2, i2, MPFR_RNDN);
            mpfr_add(zr, zr, cr, MPFR_RNDN);
            mpfr_sqr(r2, zr, MPFR_RNDN);
            mpfr_sqr(i2, zi, MPFR_RNDN);
            mpfr_add(magnitude, r2, i2, MPFR_RNDN);
            if (mpfr_cmp(magnitude, bailout) > 0) {
                mpfr_log(magnitude, magnitude, MPFR_RNDN);
                return smoothEscape(iteration, 0.5 * mpfr_get_d(magnitude, MPFR_RNDN));
            }
        }
        return -1;
    }

    float evaluate(const MBViewport& viewport, double x, double y, double aspect,
                   int maximum, const MBRenderControl* control = nullptr) {
        mpfr_mul_d(cr, viewport.span, x, MPFR_RNDN);
        mpfr_add(cr, cr, viewport.real, MPFR_RNDN);
        mpfr_mul_d(ci, viewport.span, y * aspect, MPFR_RNDN);
        mpfr_add(ci, ci, viewport.imag, MPFR_RNDN);
        mpfr_set_zero(zr, 1);
        mpfr_set_zero(zi, 1);
        for (int iteration = 1; iteration <= maximum; ++iteration) {
            if ((iteration & 63) == 0 && cancelled(control)) return -1;
            mpfr_sqr(r2, zr, MPFR_RNDN);
            mpfr_sqr(i2, zi, MPFR_RNDN);
            mpfr_mul(temporary, zr, zi, MPFR_RNDN);
            mpfr_mul_2ui(temporary, temporary, 1, MPFR_RNDN);
            mpfr_add(zi, temporary, ci, MPFR_RNDN);
            mpfr_sub(zr, r2, i2, MPFR_RNDN);
            mpfr_add(zr, zr, cr, MPFR_RNDN);
            mpfr_sqr(r2, zr, MPFR_RNDN);
            mpfr_sqr(i2, zi, MPFR_RNDN);
            mpfr_add(magnitude, r2, i2, MPFR_RNDN);
            if (mpfr_cmp_d(magnitude, kBailoutSquared) > 0) {
                // The bailout keeps this conversion safely in double range for
                // ordinary Mandelbrot coordinates. Huge input coordinates use
                // MPFR's logarithm before converting.
                mpfr_log(magnitude, magnitude, MPFR_RNDN);
                return smoothEscape(iteration, 0.5 * mpfr_get_d(magnitude, MPFR_RNDN));
            }
        }
        return -1;
    }
};

std::vector<ReferencePoint> makeReference(const MBViewport& viewport, int maximum,
                                         const MBRenderControl* control) {
    std::vector<ReferencePoint> reference;
    reference.reserve(size_t(maximum) + 1);
    reference.push_back({0, 0, {}});
    DirectWorkspace workspace(viewport.precision());
    mpfr_set_zero(workspace.zr, 1);
    mpfr_set_zero(workspace.zi, 1);
    for (int i = 0; i < maximum; ++i) {
        if ((i & 31) == 0 && cancelled(control)) break;
        mpfr_sqr(workspace.r2, workspace.zr, MPFR_RNDN);
        mpfr_sqr(workspace.i2, workspace.zi, MPFR_RNDN);
        mpfr_mul(workspace.temporary, workspace.zr, workspace.zi, MPFR_RNDN);
        mpfr_mul_2ui(workspace.temporary, workspace.temporary, 1, MPFR_RNDN);
        mpfr_add(workspace.zi, workspace.temporary, viewport.imag, MPFR_RNDN);
        mpfr_sub(workspace.zr, workspace.r2, workspace.i2, MPFR_RNDN);
        mpfr_add(workspace.zr, workspace.zr, viewport.real, MPFR_RNDN);
        reference.push_back({mpfr_get_d(workspace.zr, MPFR_RNDN),
                             mpfr_get_d(workspace.zi, MPFR_RNDN),
                             WideComplex::fromMPFR(workspace.zr, workspace.zi)});
        mpfr_sqr(workspace.r2, workspace.zr, MPFR_RNDN);
        mpfr_sqr(workspace.i2, workspace.zi, MPFR_RNDN);
        mpfr_add(workspace.magnitude, workspace.r2, workspace.i2, MPFR_RNDN);
        if (mpfr_cmp_d(workspace.magnitude, 1e12) > 0) break;
    }
    return reference;
}

bool parseJuliaParameter(const MBViewport& viewport, const char* real, const char* imag,
                          MBViewport& parameter) {
    if (!real || !imag || !mb_viewport_set(&parameter, real, imag, "1")) return false;
    if (viewport.precision() > MPFR_PREC_MAX / 2) return false;
    // Julia boundaries can be tangent to a pixel displacement, so the first
    // radial change is quadratic in that displacement. Keep a second camera's
    // worth of bits for the reference and independent fallback calculations.
    const auto bits = std::max(viewport.precision() * 2,
                               requiredPrecision(parameter.real, parameter.imag, viewport.span));
    parameter.raisePrecision(bits);
    // Decimal c is not generally a finite binary number. Reparse at the deep
    // camera's precision instead of padding a 128-bit rounded parameter.
    return mpfr_set_str(parameter.real, real, 10, MPFR_RNDN) == 0
        && mpfr_set_str(parameter.imag, imag, 10, MPFR_RNDN) == 0
        && mpfr_number_p(parameter.real) && mpfr_number_p(parameter.imag);
}

void setJuliaBailout(const MBViewport& parameter, mpfr_ptr bailout) {
    Number temporary(parameter.precision());
    mpfr_sqr(bailout, parameter.real, MPFR_RNDN);
    mpfr_sqr(temporary.value, parameter.imag, MPFR_RNDN);
    mpfr_add(bailout, bailout, temporary.value, MPFR_RNDN);
    mpfr_sqrt(bailout, bailout, MPFR_RNDN);
    mpfr_mul_2ui(bailout, bailout, 2, MPFR_RNDN);
    if (mpfr_cmp_d(bailout, kBailoutSquared) < 0) mpfr_set_d(bailout, kBailoutSquared, MPFR_RNDN);
}

std::vector<ReferencePoint> makeJuliaReference(const MBViewport& viewport,
                                               const MBViewport& parameter,
                                               mpfr_srcptr bailout, int maximum,
                                               const MBRenderControl* control) {
    std::vector<ReferencePoint> reference;
    reference.reserve(size_t(maximum) + 1);
    DirectWorkspace workspace(parameter.precision());
    mpfr_set(workspace.zr, viewport.real, MPFR_RNDN);
    mpfr_set(workspace.zi, viewport.imag, MPFR_RNDN);
    auto append = [&] {
        reference.push_back({mpfr_get_d(workspace.zr, MPFR_RNDN),
                             mpfr_get_d(workspace.zi, MPFR_RNDN),
                             WideComplex::fromMPFR(workspace.zr, workspace.zi)});
    };
    append();
    Number limit(parameter.precision());
    mpfr_mul_2ui(limit.value, bailout, 24, MPFR_RNDN);
    for (int i = 0; i < maximum; ++i) {
        if ((i & 31) == 0 && cancelled(control)) break;
        mpfr_sqr(workspace.r2, workspace.zr, MPFR_RNDN);
        mpfr_sqr(workspace.i2, workspace.zi, MPFR_RNDN);
        mpfr_mul(workspace.temporary, workspace.zr, workspace.zi, MPFR_RNDN);
        mpfr_mul_2ui(workspace.temporary, workspace.temporary, 1, MPFR_RNDN);
        mpfr_add(workspace.zi, workspace.temporary, parameter.imag, MPFR_RNDN);
        mpfr_sub(workspace.zr, workspace.r2, workspace.i2, MPFR_RNDN);
        mpfr_add(workspace.zr, workspace.zr, parameter.real, MPFR_RNDN);
        append();
        mpfr_sqr(workspace.r2, workspace.zr, MPFR_RNDN);
        mpfr_sqr(workspace.i2, workspace.zi, MPFR_RNDN);
        mpfr_add(workspace.magnitude, workspace.r2, workspace.i2, MPFR_RNDN);
        if (mpfr_cmp(workspace.magnitude, limit.value) > 0) break;
    }
    return reference;
}

struct JuliaWorker {
    const MBViewport& viewport;
    const MBViewport& parameter;
    const std::vector<ReferencePoint>& reference;
    mpfr_srcptr bailout;
    int maximum;
    const MBRenderControl* control;
    DirectWorkspace direct;
    double cr, ci, ordinaryBailout;
    uint64_t fallbacks = 0;

    JuliaWorker(const MBViewport& v, const MBViewport& p, const std::vector<ReferencePoint>& r,
                 mpfr_srcptr b, int m, const MBRenderControl* c)
        : viewport(v), parameter(p), reference(r), bailout(b), maximum(m), control(c),
          direct(p.precision()), cr(mpfr_get_d(p.real, MPFR_RNDN)),
          ci(mpfr_get_d(p.imag, MPFR_RNDN)), ordinaryBailout(mpfr_get_d(b, MPFR_RNDN)) {}

    float fallback(double x, double y, double aspect) {
        ++fallbacks;
        return direct.evaluateJulia(viewport, parameter, bailout, x, y, aspect, maximum, control);
    }

    float ordinary(double zr, double zi, double x, double y, double aspect) {
        constexpr double rounding = 8 * std::numeric_limits<double>::epsilon();
        const double parameterMagnitude = std::abs(cr) + std::abs(ci);
        double error = rounding * (std::abs(zr) + std::abs(zi));
        for (int iteration = 1; iteration <= maximum; ++iteration) {
            if ((iteration & 127) == 0 && cancelled(control)) return -1;
            const double r2 = zr * zr, i2 = zi * zi;
            const double previousNorm = r2 + i2;
            const double nextReal = r2 - i2 + cr;
            zi = 2 * zr * zi + ci;
            zr = nextReal;
            const double norm = zr * zr + zi * zi;
            if (!std::isfinite(norm)) return fallback(x, y, aspect);
            // Julia boundaries amplify small coordinate/rounding errors. Track
            // that amplification and recompute uncertain pixels with MPFR.
            error = 2 * std::sqrt(previousNorm) * error + error * error
                + rounding * (previousNorm + parameterMagnitude);
            if (error > 1e-5 * (1 + std::sqrt(norm))) return fallback(x, y, aspect);
            if (norm > ordinaryBailout) return smoothEscape(iteration, 0.5 * std::log(norm));
        }
        return -1;
    }

    float perturbation(double dr, double di, double x, double y, double aspect) {
        constexpr double rounding = 8 * std::numeric_limits<double>::epsilon();
        double error = rounding * (std::abs(dr) + std::abs(di));
        for (int iteration = 1; iteration <= maximum; ++iteration) {
            if ((iteration & 127) == 0 && cancelled(control)) return -1;
            if (size_t(iteration) >= reference.size()) return fallback(x, y, aspect);
            const auto& previous = reference[size_t(iteration - 1)];
            const double deltaMagnitude = std::abs(dr) + std::abs(di);
            const double referenceMagnitude = std::abs(previous.real) + std::abs(previous.imag);
            const double previousMagnitude = std::hypot(previous.real + dr, previous.imag + di);
            error = 2 * previousMagnitude * error + error * error
                + rounding * (2 * referenceMagnitude * deltaMagnitude + deltaMagnitude * deltaMagnitude);
            const double nextReal = 2 * (previous.real * dr - previous.imag * di) + dr * dr - di * di;
            di = 2 * (previous.real * di + previous.imag * dr + dr * di);
            dr = nextReal;
            const auto& current = reference[size_t(iteration)];
            const double zr = current.real + dr, zi = current.imag + di;
            const double norm = zr * zr + zi * zi;
            if (!std::isfinite(norm) || error > 1e-5 * (1 + std::sqrt(norm))) return fallback(x, y, aspect);
            if (norm > ordinaryBailout) return smoothEscape(iteration, 0.5 * std::log(norm));
            const double referenceNorm = current.real * current.real + current.imag * current.imag;
            if (norm < 1e-12 * referenceNorm) return fallback(x, y, aspect);
        }
        return -1;
    }

    float wide(WideComplex delta, double x, double y, double aspect) {
        constexpr double rounding = 8 * std::numeric_limits<double>::epsilon();
        auto error = magnitude(delta).scaled(rounding);
        const auto one = WideComplex::normalized(1, 0);
        for (int iteration = 1; iteration <= maximum; ++iteration) {
            if ((iteration & 127) == 0 && cancelled(control)) return -1;
            if (size_t(iteration) >= reference.size()) return fallback(x, y, aspect);
            // Attracting critical cycles can repeatedly square a vanishing
            // delta. Switch to MPFR before shared exponent arithmetic overflows.
            if (delta.exponent < std::numeric_limits<int64_t>::min() / 4
                || error.exponent < std::numeric_limits<int64_t>::min() / 4)
                return fallback(x, y, aspect);
            const auto& previous = reference[size_t(iteration - 1)].wide;
            const auto deltaMagnitude = magnitude(delta);
            error = (magnitude(previous + delta) * error).doubled() + error * error
                + ((magnitude(previous) * deltaMagnitude).doubled()
                   + deltaMagnitude * deltaMagnitude).scaled(rounding);
            delta = (previous * delta).doubled() + delta * delta;
            const auto& current = reference[size_t(iteration)].wide;
            const auto z = current + delta;
            if ((one + magnitude(z)).scaled(1e-5).magnitudeLess(error)) return fallback(x, y, aspect);
            if (z.escaped()) return smoothEscape(iteration, z.logMagnitude());
            if (!current.zero() && (z.zero() || z.magnitudeLess(current.scaled(1e-6))))
                return fallback(x, y, aspect);
        }
        return -1;
    }
};

// Expand delta_n as a polynomial in w = delta_c / scale over |w| <= 1.
// Unlike unscaled c-power coefficients, these remain in the range of the
// actual perturbations even at very deep zooms. The discarded polynomial tail
// has an explicit disk bound propagated through each recurrence. This bounds
// truncation, separately from the double rounding also present in perturbation.
InitialSeries makeInitialSeries(const std::vector<ReferencePoint>& reference,
                                 double span, double diskRadius,
                                 const MBRenderControl* control) {
    InitialSeries result;
    // At extreme exponents the extended-range BLA path avoids underflow in
    // its bounds. Do not build a double polynomial in that regime.
    if (!std::isfinite(span) || span < 1e-120 || span >= 1e-12) return result;
    result.scale = span * diskRadius;
    if (result.scale == 0 || !std::isfinite(result.scale)) return {};
    std::array<std::complex<double>, kSeriesDegree + 1> coefficients {}, next {};
    std::array<double, kSeriesDegree + 1> magnitudes {};
    double error = 0;
    for (size_t n = 0; n + 1 < reference.size(); ++n) {
        if ((n & 31) == 0 && cancelled(control)) return {};
        double magnitudeSum = 0, tail = 0;
        for (size_t i = 1; i <= kSeriesDegree; ++i) {
            magnitudes[i] = std::abs(coefficients[i]);
            magnitudeSum += magnitudes[i];
        }
        for (size_t i = 1; i <= kSeriesDegree; ++i)
            for (size_t j = kSeriesDegree + 1 - i; j <= kSeriesDegree; ++j)
                tail += magnitudes[i] * magnitudes[j];
        const std::complex<double> z(reference[n].real, reference[n].imag);
        for (size_t k = 1; k <= kSeriesDegree; ++k) {
            next[k] = 2.0 * z * coefficients[k];
            for (size_t i = 1; i < k; ++i) next[k] += coefficients[i] * coefficients[k - i];
        }
        next[1] += result.scale;
        error = (2 * std::abs(z) + 2 * magnitudeSum) * error + error * error + tail;
        coefficients.swap(next);
        double after = 0;
        for (size_t i = 1; i <= kSeriesDegree; ++i) after += std::abs(coefficients[i]);
        const double referenceMagnitude = std::hypot(reference[n + 1].real, reference[n + 1].imag);
        // The disk encloses every pixel. Check every prefix, including its
        // truncation bound, leaving a unit of margin to escape radius 256.
        if (!std::isfinite(after) || !std::isfinite(error)
            || error > 1e-17 * std::abs(coefficients[1])
            || after + referenceMagnitude + error >= 255) break;
        result.coefficients = coefficients;
        result.iterations = int(n + 1);
        result.truncationError = error;
    }
    // Horner evaluation has a fixed cost; short prefixes are cheaper to iterate.
    if (result.iterations < 64) return {};
    return result;
}

// Every leaf maps delta[m] to delta[m + 1]. Leaf zero represents m = 1,
// since the critical step at m = 0 must retain its quadratic term. Only blocks
// whose entire reference stays inside radius 255 can skip, leaving a full unit
// of margin to the radius-256 escape boundary. The tiny perturbation bound at
// every leaf also prevents a skipped cancellation/glitch or rebase event.
OrdinaryTable makeOrdinaryTable(const std::vector<ReferencePoint>& reference,
                                double maxDeltaC, const MBRenderControl* control) {
    OrdinaryTable levels;
    if (reference.size() < 4 || !std::isfinite(maxDeltaC) || maxDeltaC > kBLAEpsilon) return levels;
    std::vector<OrdinaryBLA> leaves(reference.size() - 2);
    for (size_t i = 0; i < leaves.size(); ++i) {
        if ((i & 1023) == 0 && cancelled(control)) return {};
        const auto& z = reference[i + 1];
        const auto& next = reference[i + 2];
        auto& leaf = leaves[i];
        leaf.ar = 2 * z.real;
        leaf.ai = 2 * z.imag;
        leaf.br = 1;
        const double a = std::hypot(leaf.ar, leaf.ai);
        if (std::hypot(next.real, next.imag) >= 255 || a == 0 || !std::isfinite(a)) continue;
        const double radius = kBLAEpsilon * a * kRadiusSafety;
        leaf.radius = radius;
    }
    levels.push_back(std::move(leaves));
    while (levels.back().size() >= 2) {
        const auto& lower = levels.back();
        std::vector<OrdinaryBLA> upper(lower.size() / 2);
        for (size_t i = 0; i < upper.size(); ++i) {
            if ((i & 1023) == 0 && cancelled(control)) return {};
            const auto& x = lower[2 * i];
            const auto& y = lower[2 * i + 1];
            auto& combined = upper[i];
            if (x.radius == 0 || y.radius == 0) continue;
            const double a = std::hypot(x.ar, x.ai);
            if (a == 0 || !std::isfinite(a)) continue;
            const double radius = std::min(x.radius,
                (y.radius - std::hypot(x.br, x.bi) * maxDeltaC) / a)
                * kRadiusSafety;
            if (radius <= 0 || !std::isfinite(radius)) continue;
            combined.ar = y.ar * x.ar - y.ai * x.ai;
            combined.ai = y.ar * x.ai + y.ai * x.ar;
            combined.br = y.ar * x.br - y.ai * x.bi + y.br;
            combined.bi = y.ar * x.bi + y.ai * x.br + y.bi;
            if (!std::isfinite(combined.ar) || !std::isfinite(combined.ai) ||
                !std::isfinite(combined.br) || !std::isfinite(combined.bi)) continue;
            combined.radius = radius;
        }
        levels.push_back(std::move(upper));
    }
    return levels;
}

WideTable makeWideTable(const std::vector<ReferencePoint>& reference,
                        const WideComplex& maxDeltaC, const MBRenderControl* control) {
    WideTable levels;
    if (reference.size() < 4) return levels;
    std::vector<WideBLA> leaves(reference.size() - 2);
    for (size_t i = 0; i < leaves.size(); ++i) {
        if ((i & 1023) == 0 && cancelled(control)) return {};
        const auto& z = reference[i + 1];
        const auto& next = reference[i + 2];
        auto& leaf = leaves[i];
        leaf.a = z.wide.doubled();
        leaf.b = WideComplex::normalized(1, 0);
        if (std::hypot(next.real, next.imag) >= 255 || leaf.a.zero()) continue;
        leaf.radius = magnitude(leaf.a).scaled(kBLAEpsilon * kRadiusSafety);
    }
    levels.push_back(std::move(leaves));
    while (levels.back().size() >= 2) {
        const auto& lower = levels.back();
        std::vector<WideBLA> upper(lower.size() / 2);
        for (size_t i = 0; i < upper.size(); ++i) {
            if ((i & 1023) == 0 && cancelled(control)) return {};
            const auto& x = lower[2 * i];
            const auto& y = lower[2 * i + 1];
            auto& combined = upper[i];
            if (x.radius.zero() || y.radius.zero() || x.a.zero()) continue;
            auto radius = positiveDivide(positiveDifference(y.radius, magnitude(x.b) * maxDeltaC),
                                         magnitude(x.a));
            if (x.radius.magnitudeLess(radius)) radius = x.radius;
            if (radius.zero()) continue;
            combined.a = y.a * x.a;
            combined.b = y.a * x.b + y.b;
            combined.radius = radius.scaled(kRadiusSafety);
        }
        levels.push_back(std::move(upper));
    }
    return levels;
}

// The largest aligned block starting at m is limited by trailing zeroes of
// m - 1, the number of levels, and the remaining iteration budget.
unsigned maximumLevel(size_t m, int remaining, size_t levelCount) {
    const size_t offset = m - 1;
    unsigned level = unsigned(levelCount - 1);
    if (offset) level = std::min(level, unsigned(__builtin_ctzll(offset)));
    return std::min(level, 31u - unsigned(__builtin_clz(unsigned(remaining))));
}

struct Worker {
    const MBViewport& viewport;
    const std::vector<ReferencePoint>& reference;
    const OrdinaryTable& ordinaryTable;
    const WideTable& wideTable;
    const InitialSeries& series;
    int maximum;
    const MBRenderControl* control;
    DirectWorkspace direct;
    uint64_t rebases = 0;
    uint64_t fallbacks = 0;
    uint64_t blaSteps = 0;
    uint64_t skippedIterations = 0;
    uint64_t seriesPixels = 0;

    Worker(const MBViewport& v, const PreparedReference& prepared, int m,
           const MBRenderControl* c) : viewport(v), reference(prepared.reference),
           ordinaryTable(prepared.ordinary), wideTable(prepared.wide), series(prepared.series), maximum(m),
           control(c), direct(v.precision()) {}

    float fallback(double x, double y, double aspect) {
        ++fallbacks;
        return direct.evaluate(viewport, x, y, aspect, maximum, control);
    }

    template<bool accelerated>
    float ordinary(double dx, double dy, double x, double y, double aspect) {
        double dr = 0, di = 0;
        size_t m = 0;
        int iteration = 0;
        if (accelerated && series.iterations) {
            const std::complex<double> w(dx / series.scale, dy / series.scale);
            std::complex<double> delta;
            for (size_t k = kSeriesDegree; k > 0; --k)
                delta = (delta + series.coefficients[k]) * w;
            dr = delta.real();
            di = delta.imag();
            m = size_t(series.iterations);
            iteration = series.iterations;
            ++seriesPixels;
            skippedIterations += uint64_t(iteration);
            // Apply the same precision and rebase checks at the seeded state
            // as after an ordinary step, including an orbit ending at the seed.
            const auto& current = reference[m];
            const double zr = current.real + dr, zi = current.imag + di;
            const double norm = zr * zr + zi * zi;
            const double referenceNorm = current.real * current.real + current.imag * current.imag;
            if (!std::isfinite(norm) || norm < 1e-12 * referenceNorm) return fallback(x, y, aspect);
            if (norm > kBailoutSquared) return fallback(x, y, aspect);
            if (norm < dr * dr + di * di || m + 1 >= reference.size()) {
                dr = zr; di = zi; m = 0;
                ++rebases;
            }
        }
        unsigned work = 0;
        for (; iteration < maximum;) {
            if ((++work & 127) == 0 && cancelled(control)) return -1;
            unsigned length = 0;
            // A lookup is only worthwhile for blocks of at least 16 steps.
            // Aligned starts are sparse, so ordinary iterations only pay this
            // inexpensive mask check, rather than walking the hierarchy.
            if (accelerated && m && ((m - 1) & 15) == 0 && ordinaryTable.size() > 4
                && maximum - iteration >= 16) {
                // An upper bound on the Euclidean norm avoids both sqrt per
                // lookup and squaring offsets that can be as small as 1e-270.
                const double norm = std::max(std::abs(dr), std::abs(di)) * 1.4142135623730952;
                const size_t firstIndex = (m - 1) >> 4;
                if (firstIndex < ordinaryTable[4].size() && norm < ordinaryTable[4][firstIndex].radius) {
                    for (unsigned level = maximumLevel(m, maximum - iteration, ordinaryTable.size());
                         level >= 4; --level) {
                        const auto& blocks = ordinaryTable[level];
                        const size_t index = (m - 1) >> level;
                        if (index >= blocks.size()) continue;
                        const auto& block = blocks[index];
                        if (block.radius <= norm) continue;
                        const double nextReal = block.ar * dr - block.ai * di + block.br * dx - block.bi * dy;
                        di = block.ar * di + block.ai * dr + block.br * dy + block.bi * dx;
                        dr = nextReal;
                        length = 1u << level;
                        ++blaSteps;
                        skippedIterations += length - 1;
                        break;
                    }
                }
            }
            if (!length) {
                const auto& previous = reference[m];
                const double nextReal = 2 * (previous.real * dr - previous.imag * di)
                                        + (dr * dr - di * di) + dx;
                di = 2 * (previous.real * di + previous.imag * dr + dr * di) + dy;
                dr = nextReal;
                length = 1;
            }
            m += length;
            iteration += int(length);
            const auto& current = reference[m];
            const double zr = current.real + dr;
            const double zi = current.imag + di;
            const double norm = zr * zr + zi * zi;
            if (!std::isfinite(norm)) return fallback(x, y, aspect);
            if (norm > kBailoutSquared) return smoothEscape(iteration, 0.5 * std::log(norm));
            const double referenceNorm = current.real * current.real + current.imag * current.imag;
            if (norm < 1e-12 * referenceNorm) return fallback(x, y, aspect);
            if (norm < dr * dr + di * di || m + 1 >= reference.size()) {
                dr = zr;
                di = zi;
                m = 0;
                ++rebases;
            }
        }
        return -1;
    }

    template<bool accelerated>
    float wide(const WideComplex& deltaC, double x, double y, double aspect) {
        WideComplex delta;
        size_t m = 0;
        unsigned work = 0;
        for (int iteration = 0; iteration < maximum;) {
            if ((++work & 127) == 0 && cancelled(control)) return -1;
            unsigned length = 0;
            if (accelerated && m && wideTable.size() > 1) {
                for (unsigned level = maximumLevel(m, maximum - iteration, wideTable.size());
                     level > 0; --level) {
                    const auto& blocks = wideTable[level];
                    const size_t index = (m - 1) >> level;
                    if (index >= blocks.size()) continue;
                    const auto& block = blocks[index];
                    if (!delta.magnitudeLess(block.radius)) continue;
                    delta = block.a * delta + block.b * deltaC;
                    length = 1u << level;
                    ++blaSteps;
                    skippedIterations += length - 1;
                    break;
                }
            }
            if (!length) {
                delta = (reference[m].wide * delta).doubled() + delta * delta + deltaC;
                length = 1;
            }
            m += length;
            iteration += int(length);
            const auto& current = reference[m].wide;
            const WideComplex z = current + delta;
            if (z.escaped()) return smoothEscape(iteration, z.logMagnitude());
            if (!current.zero() && (z.zero() || z.magnitudeLess(current.scaled(1e-6)))) {
                return fallback(x, y, aspect);
            }
            if (z.magnitudeLess(delta) || m + 1 >= reference.size()) {
                delta = z;
                m = 0;
                ++rebases;
            }
        }
        return -1;
    }
};

}

extern "C" {
MBViewport* mb_viewport_create(void) {
    try { return new MBViewport; } catch (...) { return nullptr; }
}

void mb_viewport_destroy(MBViewport* viewport) { delete viewport; }

MBViewport* mb_viewport_clone(const MBViewport* viewport) {
    if (!viewport) return nullptr;
    try {
        auto copy = new MBViewport;
        copy->raisePrecision(viewport->precision());
        mpfr_set(copy->real, viewport->real, MPFR_RNDN);
        mpfr_set(copy->imag, viewport->imag, MPFR_RNDN);
        mpfr_set(copy->span, viewport->span, MPFR_RNDN);
        return copy;
    } catch (...) { return nullptr; }
}

int mb_viewport_set(MBViewport* viewport, const char* real, const char* imag, const char* span) {
    if (!viewport || !real || !imag || !span) return 0;
    try {
        setExponentRange();
        MBViewport parsed;
        if (mpfr_set_str(parsed.real, real, 10, MPFR_RNDN) ||
            mpfr_set_str(parsed.imag, imag, 10, MPFR_RNDN) ||
            mpfr_set_str(parsed.span, span, 10, MPFR_RNDN) ||
            !mpfr_number_p(parsed.real) || !mpfr_number_p(parsed.imag) ||
            !mpfr_number_p(parsed.span) || mpfr_sgn(parsed.span) <= 0) return 0;
        const size_t textLength = std::max(std::strlen(real), std::strlen(imag));
        const long double textBits = textLength * 3.32192809488736234787L + kGuardBits;
        if (textBits >= static_cast<long double>(MPFR_PREC_MAX)) return 0;
        const mpfr_prec_t bits = std::max(requiredPrecision(parsed.real, parsed.imag, parsed.span),
                                          mpfr_prec_t(textBits));
        parsed.raisePrecision(bits);
        mpfr_set_str(parsed.real, real, 10, MPFR_RNDN);
        mpfr_set_str(parsed.imag, imag, 10, MPFR_RNDN);
        mpfr_set_str(parsed.span, span, 10, MPFR_RNDN);
        // An explicit new location replaces the old precision as well. This
        // releases deep-zoom storage when jumping back to an overview preset.
        mpfr_swap(viewport->real, parsed.real);
        mpfr_swap(viewport->imag, parsed.imag);
        mpfr_swap(viewport->span, parsed.span);
        return 1;
    } catch (...) { return 0; }
}

int mb_viewport_restore(MBViewport* viewport, const char* real, const char* imag,
                        const char* span, int precision_bits) {
    if (!viewport || !real || !imag || !span || precision_bits < kMinimumPrecision
        || static_cast<mpfr_prec_t>(precision_bits) > MPFR_PREC_MAX) return 0;
    try {
        setExponentRange();
        // Validate at enough precision to inspect the decimal input and its
        // depth before choosing the restored camera precision.
        MBViewport parsed;
        if (!mb_viewport_set(&parsed, real, imag, span)) return 0;
        // Metadata alone must not request gigabytes for a tiny location file.
        // Actual deep coordinates can exceed this allowance: their validated
        // precision determines the upper bound. Retained precision after
        // zooming back out is allowed even when all decimals are short/exact.
        const auto metadataLimit = std::max<mpfr_prec_t>(1000000, parsed.precision());
        if (static_cast<mpfr_prec_t>(precision_bits) > metadataLimit) return 0;
        mpfr_prec_t bits = std::max<mpfr_prec_t>(precision_bits,
            requiredPrecision(parsed.real, parsed.imag, parsed.span));
        for (;;) {
            mpfr_set_prec(parsed.real, bits);
            mpfr_set_prec(parsed.imag, bits);
            mpfr_set_prec(parsed.span, bits);
            // Parse directly at the target precision. This also avoids double
            // rounding if a caller supplies a different requested precision.
            if (mpfr_set_str(parsed.real, real, 10, MPFR_RNDN)
                || mpfr_set_str(parsed.imag, imag, 10, MPFR_RNDN)
                || mpfr_set_str(parsed.span, span, 10, MPFR_RNDN)
                || !mpfr_number_p(parsed.real) || !mpfr_number_p(parsed.imag)
                || !mpfr_number_p(parsed.span) || mpfr_sgn(parsed.span) <= 0) return 0;
            const auto required = requiredPrecision(parsed.real, parsed.imag, parsed.span);
            if (required <= bits) break;
            // Rounding a coordinate across a power of two can require another
            // guard bit. Increase precision and reparse before publishing it.
            bits = required;
        }
        mpfr_swap(viewport->real, parsed.real);
        mpfr_swap(viewport->imag, parsed.imag);
        mpfr_swap(viewport->span, parsed.span);
        return 1;
    } catch (...) { return 0; }
}

void mb_viewport_zoom(MBViewport* viewport, double factor, double anchor_x,
                      double anchor_y, double aspect) {
    if (!viewport || !std::isfinite(factor) || factor <= 0 ||
        !std::isfinite(anchor_x) || !std::isfinite(anchor_y) ||
        !std::isfinite(aspect) || aspect <= 0) return;
    try {
        setExponentRange();
        Number future(viewport->precision());
        mpfr_mul_d(future.value, viewport->span, factor, MPFR_RNDN);
        if (!mpfr_number_p(future.value) || mpfr_sgn(future.value) <= 0) return;
        viewport->raisePrecision(requiredPrecision(viewport->real, viewport->imag, future.value));
        Number shift(viewport->precision());
        Number delta(viewport->precision());
        // Compute 1 - factor at camera precision, including tiny factors that
        // would round to 1 if the subtraction were performed in double.
        mpfr_set_d(shift.value, factor, MPFR_RNDN);
        mpfr_ui_sub(shift.value, 1, shift.value, MPFR_RNDN);
        mpfr_mul(shift.value, shift.value, viewport->span, MPFR_RNDN);
        mpfr_mul_d(delta.value, shift.value, anchor_x, MPFR_RNDN);
        mpfr_add(viewport->real, viewport->real, delta.value, MPFR_RNDN);
        mpfr_mul_d(delta.value, shift.value, anchor_y * aspect, MPFR_RNDN);
        mpfr_add(viewport->imag, viewport->imag, delta.value, MPFR_RNDN);
        mpfr_mul_d(viewport->span, viewport->span, factor, MPFR_RNDN);
    } catch (...) {}
}

void mb_viewport_pan(MBViewport* viewport, double dx, double dy, double aspect) {
    if (!viewport || !std::isfinite(dx) || !std::isfinite(dy) ||
        !std::isfinite(aspect) || aspect <= 0) return;
    try {
        Number delta(viewport->precision());
        mpfr_mul_d(delta.value, viewport->span, dx, MPFR_RNDN);
        mpfr_add(viewport->real, viewport->real, delta.value, MPFR_RNDN);
        mpfr_mul_d(delta.value, viewport->span, dy * aspect, MPFR_RNDN);
        mpfr_add(viewport->imag, viewport->imag, delta.value, MPFR_RNDN);
    } catch (...) {}
}

int mb_viewport_precision(const MBViewport* viewport) {
    if (!viewport) return 0;
    return int(std::min<mpfr_prec_t>(viewport->precision(), std::numeric_limits<int>::max()));
}

double mb_viewport_log_zoom(const MBViewport* viewport) {
    if (!viewport) return 0;
    mpfr_exp_t exponent;
    const double mantissa = mpfr_get_d_2exp(&exponent, viewport->span, MPFR_RNDN);
    return std::log10(3.5) - std::log10(mantissa) - double(exponent) * std::log10(2.0);
}

char* mb_viewport_describe(const MBViewport* viewport) {
    if (!viewport) return nullptr;
    char* real = nullptr;
    char* imag = nullptr;
    char* span = nullptr;
    try {
        const long double digits = viewport->precision() * 0.30102999566398119521L + 3;
        if (digits >= std::numeric_limits<int>::max()) return nullptr;
        const int count = int(digits);
        if (mpfr_asprintf(&real, "%.*Rg", count, viewport->real) < 0 ||
            mpfr_asprintf(&imag, "%.*Rg", count, viewport->imag) < 0 ||
            mpfr_asprintf(&span, "%.*Rg", count, viewport->span) < 0) throw std::bad_alloc();
        std::string result = "{\"real\":\"" + std::string(real) + "\",\"imag\":\"" + imag
                            + "\",\"span\":\"" + span + "\",\"bits\":"
                            + std::to_string(viewport->precision()) + "}";
        mpfr_free_str(real);
        mpfr_free_str(imag);
        mpfr_free_str(span);
        return ::strdup(result.c_str());
    } catch (...) {
        if (real) mpfr_free_str(real);
        if (imag) mpfr_free_str(imag);
        if (span) mpfr_free_str(span);
        return nullptr;
    }
}

void mb_string_free(char* string) { std::free(string); }

MBRenderControl* mb_render_control_create(void) {
    try { return new MBRenderControl; } catch (...) { return nullptr; }
}

void mb_render_control_cancel(MBRenderControl* control) {
    if (control) control->cancelled.store(true, std::memory_order_relaxed);
}

double mb_render_control_progress(const MBRenderControl* control) {
    if (!control) return 0;
    const int height = control->renderHeight.load(std::memory_order_relaxed);
    if (height <= 0) return 0;
    return std::clamp(double(control->completedRows.load(std::memory_order_relaxed)) / height, 0.0, 1.0);
}

void mb_render_control_set_acceleration(MBRenderControl* control, int enabled) {
    if (control) control->acceleration.store(enabled != 0, std::memory_order_relaxed);
}

void mb_render_control_destroy(MBRenderControl* control) { delete control; }

void mb_render_control_get_stats(const MBRenderControl* control, MBRenderStats* stats) {
    if (!stats) return;
    if (!control) { *stats = {}; return; }
    std::lock_guard<std::mutex> lock(control->statsMutex);
    *stats = control->stats;
}

int mb_render(const MBViewport* viewport, int width, int height, int max_iterations,
              float* output, MBRenderControl* control) {
    if (!viewport || !output || width <= 0 || height <= 0 || max_iterations <= 0 ||
        size_t(width) > std::numeric_limits<size_t>::max() / size_t(height) / sizeof(float)) return -1;
    if (cancelled(control)) return 0;
    const auto start = std::chrono::steady_clock::now();
    try {
        std::unique_lock<std::mutex> renderLock;
        if (control) renderLock = std::unique_lock<std::mutex>(control->renderMutex);
        if (cancelled(control)) return 0;
        if (control) {
            control->completedRows.store(0, std::memory_order_relaxed);
            control->renderHeight.store(height, std::memory_order_relaxed);
        }
        setExponentRange();
        std::unique_ptr<PreparedReference> localPrepared;
        auto& cached = control ? control->prepared : localPrepared;
        const bool reused = cached && cached->matches(*viewport, max_iterations);
        if (!reused) {
            auto prepared = std::make_unique<PreparedReference>();
            prepared->snapshot(*viewport, max_iterations);
            prepared->reference = makeReference(*viewport, max_iterations, control);
            // Publish only a complete reference, so an allocation failure is
            // safe to retry using the same camera and render control.
            cached = std::move(prepared);
        }
        if (cancelled(control)) return 0;
        const auto& reference = cached->reference;
        const bool useWide = mpfr_get_exp(viewport->span) < -900;
        const double span = mpfr_get_d(viewport->span, MPFR_RNDN);
        const double centerReal = mpfr_get_d(viewport->real, MPFR_RNDN);
        const double centerImag = mpfr_get_d(viewport->imag, MPFR_RNDN);
        const double aspect = double(height) / width;
        Number zero(viewport->precision());
        mpfr_set_zero(zero.value, 1);
        const auto wideSpan = WideComplex::fromMPFR(viewport->span, zero.value);
        const bool accelerate = !control || control->acceleration.load(std::memory_order_relaxed);
        if (accelerate && aspect > cached->aspectBound) {
            // Allow slightly different preview/full aspect ratios caused by
            // integer image dimensions to share the same conservative tables.
            const double aspectBound = std::ceil(aspect * 16) / 16 + 1.0 / 16;
            const double radius = 0.5 * std::hypot(1.0, aspectBound) / kRadiusSafety;
            if (useWide) cached->wide = makeWideTable(reference, wideSpan.scaled(radius), control);
            else {
                auto ordinary = makeOrdinaryTable(reference, span * radius, control);
                auto series = makeInitialSeries(reference, span, radius, control);
                cached->ordinary = std::move(ordinary);
                cached->series = std::move(series);
            }
            cached->aspectBound = aspectBound;
        } else if (!accelerate) {
            cached->ordinary.clear();
            cached->wide.clear();
            cached->series = {};
            cached->aspectBound = 0;
        }
        if (cancelled(control)) return 0;
        std::atomic<int> nextRow {0};
        std::atomic<uint64_t> rebaseCount {0};
        std::atomic<uint64_t> fallbackCount {0};
        std::atomic<uint64_t> blaCount {0};
        std::atomic<uint64_t> skippedCount {0};
        std::atomic<uint64_t> seriesCount {0};
        std::atomic<bool> failed {false};
        const unsigned available = std::max(1u, std::thread::hardware_concurrency());
        const int workerCount = std::min(height, int(std::min(12u, available)));
        auto work = [&] {
            setExponentRange();
            try {
                Worker worker(*viewport, *cached, max_iterations, control);
                while (!cancelled(control) && !failed.load(std::memory_order_relaxed)) {
                    const int first = nextRow.fetch_add(4, std::memory_order_relaxed);
                    if (first >= height) break;
                    for (int row = first; row < std::min(height, first + 4); ++row) {
                        if (cancelled(control)) break;
                        const double y = 0.5 - (double(row) + 0.5) / height;
                        const double dy = y * aspect * span;
                        for (int column = 0; column < width; ++column) {
                            const double x = (double(column) + 0.5) / width - 0.5;
                            const double dx = x * span;
                            float result;
                            if (definitelyInterior(centerReal + dx, centerImag + dy)) {
                                result = -1;
                            } else if (useWide) {
                                const WideComplex offset = WideComplex::normalized(x, y * aspect);
                                result = cached->wide.empty()
                                    ? worker.wide<false>(wideSpan * offset, x, y, aspect)
                                    : worker.wide<true>(wideSpan * offset, x, y, aspect);
                            } else if (!std::isfinite(centerReal) || !std::isfinite(centerImag) ||
                                       !std::isfinite(span)) {
                                result = worker.fallback(x, y, aspect);
                            } else {
                                result = cached->ordinary.empty() && !cached->series.iterations
                                    ? worker.ordinary<false>(dx, dy, x, y, aspect)
                                    : worker.ordinary<true>(dx, dy, x, y, aspect);
                            }
                            output[size_t(row) * width + column] = result;
                            if ((column & 31) == 31 && cancelled(control)) break;
                        }
                        if (control && !cancelled(control))
                            control->completedRows.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                rebaseCount.fetch_add(worker.rebases, std::memory_order_relaxed);
                fallbackCount.fetch_add(worker.fallbacks, std::memory_order_relaxed);
                blaCount.fetch_add(worker.blaSteps, std::memory_order_relaxed);
                skippedCount.fetch_add(worker.skippedIterations, std::memory_order_relaxed);
                seriesCount.fetch_add(worker.seriesPixels, std::memory_order_relaxed);
            } catch (...) { failed.store(true, std::memory_order_relaxed); }
            mpfr_free_cache();
        };
        std::vector<std::thread> threads;
        threads.reserve(size_t(workerCount - 1));
        try {
            for (int i = 1; i < workerCount; ++i) threads.emplace_back(work);
        } catch (...) {
            failed.store(true, std::memory_order_relaxed);
            for (auto& thread : threads) thread.join();
            return -1;
        }
        work();
        for (auto& thread : threads) thread.join();
        if (control) {
            std::lock_guard<std::mutex> lock(control->statsMutex);
            control->stats = {mb_viewport_precision(viewport), int(reference.size() - 1),
                              useWide ? 1 : 0, rebaseCount.load(), fallbackCount.load(),
                              blaCount.load(), skippedCount.load(), seriesCount.load(),
                              cached->series.iterations, reused ? 1 : 0,
                              std::chrono::duration<double, std::milli>(
                                  std::chrono::steady_clock::now() - start).count()};
        }
        if (failed.load()) return -1;
        return cancelled(control) ? 0 : 1;
    } catch (...) { return -1; }
}

int mb_render_julia(const MBViewport* viewport, const char* parameter_real,
                    const char* parameter_imag, int width, int height,
                    int max_iterations, float* output, MBRenderControl* control) {
    if (!viewport || !parameter_real || !parameter_imag || !output || width <= 0 || height <= 0
        || max_iterations <= 0
        || size_t(width) > std::numeric_limits<size_t>::max() / size_t(height) / sizeof(float)) return -1;
    if (cancelled(control)) return 0;
    const auto start = std::chrono::steady_clock::now();
    try {
        std::unique_lock<std::mutex> renderLock;
        if (control) renderLock = std::unique_lock<std::mutex>(control->renderMutex);
        if (cancelled(control)) return 0;
        if (control) {
            control->completedRows.store(0, std::memory_order_relaxed);
            control->renderHeight.store(height, std::memory_order_relaxed);
        }
        setExponentRange();
        MBViewport parameter;
        if (!parseJuliaParameter(*viewport, parameter_real, parameter_imag, parameter)) return -1;
        Number bailout(parameter.precision());
        setJuliaBailout(parameter, bailout.value);
        const double span = mpfr_get_d(viewport->span, MPFR_RNDN);
        const double centerReal = mpfr_get_d(viewport->real, MPFR_RNDN);
        const double centerImag = mpfr_get_d(viewport->imag, MPFR_RNDN);
        const double cr = mpfr_get_d(parameter.real, MPFR_RNDN);
        const double ci = mpfr_get_d(parameter.imag, MPFR_RNDN);
        const bool finite = std::isfinite(span) && std::isfinite(centerReal)
            && std::isfinite(centerImag) && std::isfinite(cr) && std::isfinite(ci)
            && std::isfinite(mpfr_get_d(bailout.value, MPFR_RNDN));
        const bool useDirect = finite && span / width > 1e-12 * (1 + std::hypot(centerReal, centerImag));
        // Julia has no additive delta-c term: at a critical reference point
        // its initial delta is squared. Enter extended range before that square
        // could underflow, including the smallest supported pixel offsets.
        const bool useWide = mpfr_get_exp(viewport->span) < -450;
        const bool standardBailout = mpfr_cmp_d(bailout.value, kBailoutSquared) == 0;
        // Shallow views use the inexpensive Julia recurrence directly. Deep
        // views share a high-precision orbit starting at the viewport center.
        const auto reference = useDirect ? std::vector<ReferencePoint>()
            : makeJuliaReference(*viewport, parameter, bailout.value, max_iterations, control);
        if (cancelled(control)) return 0;
        Number zero(parameter.precision());
        mpfr_set_zero(zero.value, 1);
        const auto wideSpan = WideComplex::fromMPFR(viewport->span, zero.value);
        const double aspect = double(height) / width;
        std::atomic<int> nextRow {0};
        std::atomic<uint64_t> fallbackCount {0};
        std::atomic<bool> failed {false};
        const unsigned available = std::max(1u, std::thread::hardware_concurrency());
        const int workerCount = std::min(height, int(std::min(12u, available)));
        auto work = [&] {
            setExponentRange();
            try {
                JuliaWorker worker(*viewport, parameter, reference, bailout.value, max_iterations, control);
                while (!cancelled(control) && !failed.load(std::memory_order_relaxed)) {
                    const int first = nextRow.fetch_add(4, std::memory_order_relaxed);
                    if (first >= height) break;
                    for (int row = first; row < std::min(height, first + 4); ++row) {
                        if (cancelled(control)) break;
                        const double y = 0.5 - (double(row) + 0.5) / height;
                        const double dy = y * aspect * span;
                        for (int column = 0; column < width; ++column) {
                            const double x = (double(column) + 0.5) / width - 0.5;
                            const double dx = x * span;
                            float result;
                            if (useDirect) result = worker.ordinary(centerReal + dx, centerImag + dy, x, y, aspect);
                            else if (useWide)
                                result = standardBailout
                                    ? worker.wide(wideSpan * WideComplex::normalized(x, y * aspect), x, y, aspect)
                                    : worker.fallback(x, y, aspect);
                            else if (!finite) result = worker.fallback(x, y, aspect);
                            else result = worker.perturbation(dx, dy, x, y, aspect);
                            output[size_t(row) * width + column] = result;
                            if ((column & 31) == 31 && cancelled(control)) break;
                        }
                        if (control && !cancelled(control))
                            control->completedRows.fetch_add(1, std::memory_order_relaxed);
                    }
                }
                fallbackCount.fetch_add(worker.fallbacks, std::memory_order_relaxed);
            } catch (...) { failed.store(true, std::memory_order_relaxed); }
            mpfr_free_cache();
        };
        std::vector<std::thread> threads;
        threads.reserve(size_t(workerCount - 1));
        try {
            for (int i = 1; i < workerCount; ++i) threads.emplace_back(work);
        } catch (...) {
            failed.store(true, std::memory_order_relaxed);
            for (auto& thread : threads) thread.join();
            return -1;
        }
        work();
        for (auto& thread : threads) thread.join();
        if (control) {
            MBRenderStats stats {};
            stats.precision_bits = int(std::min<mpfr_prec_t>(parameter.precision(), std::numeric_limits<int>::max()));
            stats.reference_iterations = reference.empty() ? 0 : int(reference.size() - 1);
            stats.wide_exponent = useWide ? 1 : 0;
            stats.fallback_pixels = fallbackCount.load();
            stats.elapsed_milliseconds = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            std::lock_guard<std::mutex> lock(control->statsMutex);
            control->stats = stats;
        }
        if (failed.load()) return -1;
        return cancelled(control) ? 0 : 1;
    } catch (...) { return -1; }
}

int mb_sample_julia_mpfr(const MBViewport* viewport, const char* parameter_real,
                         const char* parameter_imag, double x, double y, double aspect,
                         int max_iterations, float* value) {
    if (!viewport || !parameter_real || !parameter_imag || !value || !std::isfinite(x)
        || !std::isfinite(y) || !std::isfinite(aspect) || aspect <= 0 || max_iterations <= 0) return 0;
    try {
        setExponentRange();
        MBViewport parameter;
        if (!parseJuliaParameter(*viewport, parameter_real, parameter_imag, parameter)) return 0;
        Number bailout(parameter.precision());
        setJuliaBailout(parameter, bailout.value);
        DirectWorkspace direct(parameter.precision());
        *value = direct.evaluateJulia(*viewport, parameter, bailout.value, x, y, aspect, max_iterations);
        return 1;
    } catch (...) { return 0; }
}

int mb_sample_mpfr(const MBViewport* viewport, double x, double y, double aspect,
                   int max_iterations, float* value) {
    if (!viewport || !value || !std::isfinite(x) || !std::isfinite(y) ||
        !std::isfinite(aspect) || aspect <= 0 || max_iterations <= 0) return 0;
    try {
        setExponentRange();
        DirectWorkspace direct(viewport->precision());
        *value = direct.evaluate(*viewport, x, y, aspect, max_iterations);
        return 1;
    } catch (...) { return 0; }
}
}
