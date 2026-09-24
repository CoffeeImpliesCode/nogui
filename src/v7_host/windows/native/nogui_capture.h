/*
 * Narrow C ABI over Windows.Graphics.Capture, delivering CPU pixel buffers.
 *
 * The implementation is a C++ translation unit because the capture ABI is not
 * C-shaped: the frame pool takes a `SizeInt32` by value, the frame's content
 * size comes back in a register, and the picker returns a projected
 * `IAsyncOperation<GraphicsCaptureItem>`. Hand-writing those in C means
 * hand-writing vtables and argument-passing conventions, which is where a
 * binding silently calls the wrong slot. C++/WinRT states all of them, and this
 * header stays plain C so a Zig `extern` can bind it exactly.
 *
 * The capture API hands back `IDirect3DSurface` objects that only a D3D11 device
 * can read, so a provider that wants an `image.FrameDescriptor` has to make that
 * read a CPU copy. The device this library creates is a *capture-only* device: it
 * is never handed to the renderer, and the render path keeps using noapi. A
 * staging texture is the copy, and `Map` on it is what produces the bytes the
 * host publishes.
 *
 * **One context per session.** Every object below lives in a `nogui_capture`
 * the caller owns. Nothing is process-wide except the capability probe, so two
 * providers capturing two windows cannot stop each other: one provider's
 * `nogui_capture_stop` releases only its own session, pool and staging texture.
 *
 * **Threading.** The picker, the session and the frame pool are WinRT objects,
 * and this library initializes the calling thread for the multithreaded
 * apartment. That is not a preference: a WinRT completion arrives on a thread
 * pool thread only in the multithreaded apartment, and `nogui_capture_picker_wait`
 * blocks the caller until the user answers, so on a single-threaded apartment the
 * status it polls would never advance. A thread already initialized in another
 * apartment is refused by name rather than waited on forever.
 *
 * Every entry point except the two release calls and the capability probe must be
 * called from the thread that opened the context. A call from another thread
 * reports `NOGUI_CAPTURE_FAILED` with `ERROR_INVALID_THREAD` as the last HRESULT
 * rather than touching objects it does not own.
 *
 * **Frame ownership.** A frame handed back is a CPU copy this library owns until
 * `nogui_capture_frame_release`, which wipes the pixels and frees the buffer. The
 * platform frame itself is returned to the pool as soon as the copy is complete,
 * so a release is one wipe and one free. The host copies out of the descriptor
 * and releases it exactly once; a second release is a no-op rather than a double
 * free, because the release zeroes the descriptor it was given.
 */
#ifndef NOGUI_CAPTURE_H
#define NOGUI_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors the status enum in src/v7_host/windows/capture.zig. */
typedef enum nogui_capture_status {
    NOGUI_CAPTURE_OK = 0,
    /* The picker closed with no selection. Nothing was captured. */
    NOGUI_CAPTURE_CANCELED = 1,
    /* The user or policy refused. Distinct from canceled. */
    NOGUI_CAPTURE_DENIED = 2,
    /* The platform cannot capture on this machine, or the calling thread is in
     * an apartment this path cannot use. Nothing was shown to a user. */
    NOGUI_CAPTURE_UNAVAILABLE = 3,
    /* The call failed and may be retried. */
    NOGUI_CAPTURE_FAILED = 4,
    /* A frame was not available before the timeout expired. */
    NOGUI_CAPTURE_TIMEOUT = 5,
    /* The negotiated surface is one this build cannot describe: not BGRA8 or
     * RGBA8, or a multisampled surface that has no CPU-readable equivalent. */
    NOGUI_CAPTURE_BAD_FORMAT = 6
} nogui_capture_status;

/* One capture session's platform objects. Opaque on purpose: the context holds
 * C++/WinRT types that a C caller has no business naming, and it is the unit
 * that stops one provider's stop from being another's. */
typedef struct nogui_capture nogui_capture;


/* Which D3D11 driver type the capture device came from. Declared rather than
 * assumed: a machine with no usable hardware adapter still captures, on the CPU,
 * and a caller that reports its capture backend should say so. */
typedef enum nogui_capture_driver {
    NOGUI_CAPTURE_DRIVER_UNKNOWN = 0,
    NOGUI_CAPTURE_DRIVER_HARDWARE = 1,
    NOGUI_CAPTURE_DRIVER_WARP = 2
} nogui_capture_driver;

/* One CPU frame. `data` is owned by the library until the matching release. */
typedef struct nogui_capture_frame {
    unsigned char *data;
    unsigned int width;
    unsigned int height;
    unsigned int stride;
    /* 0 is BGRA8, 1 is RGBA8. The host maps these onto `PixelFormat`. */
    unsigned int format;
    /*
     * Presentation time in nanoseconds, taken from the frame's
     * `SystemRelativeTime`, which is a QPC reading rather than a wall clock and
     * is converted here with the machine's QPC frequency. Zero when the
     * platform reported no timestamp or the frequency could not be read.
     */
    unsigned long long timestamp_ns;
    /*
     * The library's own handle for this frame: the allocation record. It
     * travels beside the descriptor and never inside `data`, because `data` is
     * the picture and its first bytes are pixels. It is NULL on a frame the
     * library does not own, which is what makes a second release a no-op rather
     * than a double free.
     */
    void *owner;
} nogui_capture_frame;

/*
 * True when this machine can capture at all.
 *
 * The answer is `GraphicsCaptureSession::IsSupported`, which is the platform's
 * documented own answer to that question. The call allocates nothing that
 * outlives it and works on any thread, so a host can ask without opening a
 * context.
 */
int nogui_capture_supported(void);

/*
 * Open a capture context: initialize the calling thread for WinRT, create the
 * capture-only D3D11 device and the frame-arrival event.
 *
 * The device is created with `D3D11_CREATE_DEVICE_BGRA_SUPPORT`, which is the
 * one creation flag the capture samples use. A hardware device is tried first
 * and the software rasterizer is a real second attempt, not a stub: a machine
 * with no usable hardware adapter still captures, on the CPU.
 */
nogui_capture_status nogui_capture_open(nogui_capture **out);

/* The driver the context's device came from. `nogui_capture_driver_name` is its
 * stable name for a status message. */
nogui_capture_driver nogui_capture_driver_of(const nogui_capture *cap);
const char *nogui_capture_driver_name(const nogui_capture *cap);

/*
 * Release every resource the context holds. Frames the consumer still holds are
 * CPU copies and survive this; their release stays valid. Safe on NULL.
 */
void nogui_capture_close(nogui_capture *cap);

/*
 * Show the system capture picker, parented to `hwnd`.
 *
 * This is the consent step, and it is the only way this library obtains a
 * capture item. The dialog is the OS's own; nothing here decides what the user
 * may capture, and `hwnd` is the only thing the host contributes. A NULL `hwnd`
 * leaves the picker unowned.
 *
 * A second pick while one is pending is refused rather than replacing the
 * pending answer, which would leave the first dialog's result unreachable.
 */
nogui_capture_status nogui_capture_picker_show(nogui_capture *cap, void *hwnd);

/* Non-blocking answer to the pending pick. On OK, `*out_item` is an item the
 * caller owns and must release with `nogui_capture_item_destroy`. */
nogui_capture_status nogui_capture_picker_poll(nogui_capture *cap, void **out_item);

/*
 * Wait for the picker's answer, at most `timeout_ms`. A negative timeout waits
 * indefinitely.
 *
 * Returns NOGUI_CAPTURE_CANCELED when the user closed it with no selection and
 * NOGUI_CAPTURE_DENIED when the user or policy refused.
 */
nogui_capture_status nogui_capture_picker_wait(nogui_capture *cap, int timeout_ms,
                                               void **out_item);

/* Release a capture item. Safe on NULL. */
void nogui_capture_item_destroy(void *item);

/*
 * Start capturing `item` into a free-threaded frame pool.
 *
 * A size of zero takes the item's own size, which is what the platform says the
 * content is. The pool holds two buffers, which is what the platform's own
 * samples pass; the SDK documents no minimum.
 *
 * The session belongs to this context and stops with it. The item stays the
 * caller's: it is not closed here, because a `GraphicsCaptureItem` is what the
 * caller may attach a second session to, and the SDK gives it no `Close` at all.
 */
nogui_capture_status nogui_capture_start(nogui_capture *cap, void *item,
                                         unsigned int width, unsigned int height);

/* Stop the session and release the frame pool. Safe when nothing is started. */
void nogui_capture_stop(nogui_capture *cap);
/*
 * Take the next available frame, waiting up to `timeout_ms`.
 *
 * On OK the frame is owned by the caller until `nogui_capture_frame_release`. A
 * frame that cannot be mapped, or whose format is not one the host can describe,
 * is released before this returns and reported rather than handed over as
 * unreadable bytes. An invalidated source, which is how Windows reports a
 * display or policy change, is NOGUI_CAPTURE_UNAVAILABLE.
 */
nogui_capture_status nogui_capture_next_frame(nogui_capture *cap,
                                              nogui_capture_frame *out,
                                              int timeout_ms);

/* Release a frame. Safe on a zeroed frame and safe to call twice. */
void nogui_capture_frame_release(nogui_capture_frame *frame);

/* The last platform HRESULT, for a host that wants the reason behind FAILED. */
long nogui_capture_last_hresult(const nogui_capture *cap);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_CAPTURE_H */
