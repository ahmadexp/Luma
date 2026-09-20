#ifndef FRACTAL_CORE_H
#define FRACTAL_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MBViewport MBViewport;
typedef struct MBRenderControl MBRenderControl;

typedef struct MBRenderStats {
    int precision_bits;
    int reference_iterations;
    int wide_exponent;
    uint64_t rebases;
    uint64_t fallback_pixels;
    uint64_t bla_steps;
    /* Recurrences avoided by BLA blocks and the shared series prefix. */
    uint64_t skipped_iterations;
    uint64_t series_pixels;
    int series_iterations;
    int reference_reused;
    double elapsed_milliseconds;
} MBRenderStats;

MBViewport* mb_viewport_create(void);
void mb_viewport_destroy(MBViewport* viewport);
MBViewport* mb_viewport_clone(const MBViewport* viewport);
int mb_viewport_set(MBViewport* viewport, const char* real, const char* imag, const char* span);
/* Restore serialized decimal camera values without accumulating extra text
 * guard bits. Uses at least precision_bits and the precision required by span.
 * Standalone saved precision metadata is bounded; deeper coordinates can
 * establish a larger bound. Invalid input leaves the viewport unchanged. */
int mb_viewport_restore(MBViewport* viewport, const char* real, const char* imag,
                        const char* span, int precision_bits);
/* Span is horizontal. x/y are centered coordinates, positive y points upward.
 * aspect is image height / width. factor < 1 zooms in around the anchor. */
void mb_viewport_zoom(MBViewport* viewport, double factor, double anchor_x, double anchor_y, double aspect);
void mb_viewport_pan(MBViewport* viewport, double dx, double dy, double aspect);
int mb_viewport_precision(const MBViewport* viewport);
double mb_viewport_log_zoom(const MBViewport* viewport);
/* JSON with decimal strings real, imag, span, and integer bits. */
char* mb_viewport_describe(const MBViewport* viewport);
void mb_string_free(char* string);

MBRenderControl* mb_render_control_create(void);
void mb_render_control_cancel(MBRenderControl* control);
/* Thread-safe row completion fraction for the current render, in [0, 1]. */
double mb_render_control_progress(const MBRenderControl* control);
/* Enabled by default. Disable for numerical comparisons with plain perturbation.
 * Set before rendering. A control caches its reference across sequential calls. */
void mb_render_control_set_acceleration(MBRenderControl* control, int enabled);
void mb_render_control_destroy(MBRenderControl* control);
void mb_render_control_get_stats(const MBRenderControl* control, MBRenderStats* stats);

/* Row-major smooth escape values, -1 for points not escaping in the iteration
 * budget. Top row is positive imaginary. Returns 1 on success, 0 if cancelled,
 * or -1 for an invalid argument/allocation failure. Clone the viewport before
 * concurrent camera edits. Calls sharing a control are serialized; repeated calls
 * reuse the reference when the camera and iteration budget match. The control
 * cannot be reused after cancellation. */
int mb_render(const MBViewport* viewport, int width, int height, int max_iterations,
              float* output, MBRenderControl* control);

/* Julia dynamics z <- z*z + c, with the viewport specifying initial z.
 * The fixed parameter is parsed at the camera's arbitrary precision. Output,
 * iteration, cancellation, and image orientation conventions match mb_render. */
int mb_render_julia(const MBViewport* viewport, const char* parameter_real,
                    const char* parameter_imag, int width, int height,
                    int max_iterations, float* output, MBRenderControl* control);
int mb_sample_julia_mpfr(const MBViewport* viewport, const char* parameter_real,
                         const char* parameter_imag, double x, double y, double aspect,
                         int max_iterations, float* value);

/* Independent direct MPFR evaluator, primarily for numerical verification. */
int mb_sample_mpfr(const MBViewport* viewport, double x, double y, double aspect,
                   int max_iterations, float* value);

#ifdef __cplusplus
}
#endif
#endif
