/*
 * Windows.Graphics.Capture, delivering CPU pixel buffers.
 *
 * This is a C++ translation unit on purpose. The capture ABI is not C-shaped:
 * the frame pool takes a `SizeInt32` by value, a frame's content size comes back
 * through a pointer into caller storage, and the picker returns a projected
 * `IAsyncOperation<GraphicsCaptureItem>`. Spelled out by hand in C, those are
 * three places to get an argument-passing convention wrong, and a wrong one does
 * not fail loudly: it calls a neighbouring vtable slot. C++/WinRT states every
 * one of them, and the `extern "C"` surface stays plain C so a Zig `extern` can
 * bind it exactly.
 *
 * The pipeline, in the order the SDK requires:
 *
 *   1. `GraphicsCapturePicker` is activated and, when the host has an owner
 *      window, parented to it through `IInitializeWithWindow`. It is the OS's own
 *      dialog and the only way this library obtains a capture item, because the
 *      item is what carries the user's consent.
 *   2. `PickSingleItemAsync` shows it. The operation is polled through its status
 *      rather than awaited, so the caller keeps one code path whether it waits or
 *      polls.
 *   3. The chosen `GraphicsCaptureItem` is attached to a session created by the
 *      frame pool: `CreateCaptureSession` is a method on
 *      `Direct3D11CaptureFramePool`, and it is the only way to make a session.
 *   4. `StartCapture` begins delivery. The item is never closed: the SDK gives it
 *      no `Close` at all, and the caller keeps it because one item may back more
 *      than one session.
 *   5. A free-threaded `Direct3D11CaptureFramePool` delivers
 *      `Direct3D11CaptureFrame`s, each carrying an `IDirect3DSurface`.
 *   6. `IDirect3DDxgiInterfaceAccess` on that surface is the underlying
 *      `ID3D11Texture2D`, which is copied into a staging texture and mapped.
 *
 * Step 6 is why this file owns a D3D11 device at all. The surface is a D3D
 * object and there is no CPU path around it. The device is capture-only: it is
 * never published to the renderer, and the render path keeps using noapi. It is
 * created with `D3D11_CREATE_DEVICE_BGRA_SUPPORT`, the one creation flag the
 * platform's own capture samples pass. A machine with no usable hardware adapter
 * gets the software rasterizer instead, and which one it got is reported through
 * `nogui_capture_driver_of` rather than assumed.
 *
 * Everything lives in one `nogui_capture` the caller owns, so one provider's stop
 * releases only its own session, pool and staging texture and cannot end another
 * provider's capture.
 *
 * Threading: this library initializes the calling thread for the multithreaded
 * apartment and balances it on close. That is what lets `nogui_capture_picker_wait`
 * block and still make progress: a WinRT completion reaches the caller through
 * the thread pool, which happens without the caller pumping anything. A thread
 * already in another apartment is refused by name rather than waited on until the
 * user gives up.
 */
#include "nogui_capture.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <roapi.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>

using Microsoft::WRL::ComPtr;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Foundation::IInspectable;
using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCapturePicker;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::SizeInt32;

namespace {

/*
 * Two buffers, which is what the platform's own samples pass. The SDK documents
 * the parameter as "the number of buffers in which to store captured frames"
 * without a minimum, so this is a chosen depth and not a documented floor.
 */
constexpr int32_t k_pool_buffer_count = 2;

/* How often the picker's status is read while the caller waits. */
constexpr DWORD k_pick_poll_ms = 10;

/* One frame's CPU copy, owned until the host releases it. */
struct nogui_capture_owned_frame {
    unsigned char *data;
    std::size_t size;
    /* The mapped row pitch the copy was made with. It is not `width * 4` on most
     * adapters, and the host needs it to find row N. */
    unsigned int stride;
};


} // namespace

/*
 * One capture session's platform objects. The type is defined here rather than in
 * the header because its members are C++/WinRT types, which a C caller has no
 * business naming.
 */
struct nogui_capture {
    DWORD thread_id = 0;
    /* True when this context called `RoInitialize` and so owes a `RoUninitialize`. */
    bool apartment_initialized = false;
    nogui_capture_driver driver = NOGUI_CAPTURE_DRIVER_UNKNOWN;
    HRESULT last_hresult = S_OK;

    /* Capture-only D3D11 objects. Never published to the renderer. */
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDirect3DDevice> winrt_device;

    /* The pending pick and its answer. */
    IAsyncOperation<GraphicsCaptureItem> pick{nullptr};

    /* The running session. */
    GraphicsCaptureItem item{nullptr};
    GraphicsCaptureSession session{nullptr};
    Direct3D11CaptureFramePool pool{nullptr};
    winrt::event_token frame_token{};
    winrt::event_token closed_token{};
    HANDLE frame_ready = nullptr;
    /* 1 when a frame may be waiting, -1 when the source was invalidated. */
    volatile LONG frame_pending = 0;

    /* One reusable staging texture, so a steady stream does not allocate one per
     * frame. It is recreated whenever the negotiated size changes. */
    ComPtr<ID3D11Texture2D> staging;
    unsigned int staging_width = 0;
    unsigned int staging_height = 0;
};

namespace {

/* Record the reason a call failed, and name it as a status the host can act on. */
nogui_capture_status nogui_capture_status_from(nogui_capture *cap, HRESULT hr) {
    cap->last_hresult = hr;
    if (SUCCEEDED(hr)) {
        return NOGUI_CAPTURE_OK;
    }
    switch (hr) {
    case E_ACCESSDENIED:
    case HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED):
        return NOGUI_CAPTURE_DENIED;
    case HRESULT_FROM_WIN32(ERROR_CANCELLED):
        return NOGUI_CAPTURE_CANCELED;
    case REGDB_E_CLASSNOTREG:
    case CLASS_E_CLASSNOTAVAILABLE:
    case DXGI_ERROR_NOT_FOUND:
    case HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED):
        return NOGUI_CAPTURE_UNAVAILABLE;
    case E_INVALIDARG:
    case DXGI_ERROR_UNSUPPORTED:
        return NOGUI_CAPTURE_BAD_FORMAT;
    default:
        return NOGUI_CAPTURE_FAILED;
    }
}

nogui_capture_status nogui_capture_failed(nogui_capture *cap, HRESULT hr) {
    cap->last_hresult = hr;
    return NOGUI_CAPTURE_FAILED;
}

nogui_capture_status nogui_capture_unavailable(nogui_capture *cap, HRESULT hr) {
    cap->last_hresult = hr;
    return NOGUI_CAPTURE_UNAVAILABLE;
}

/*
 * Every entry point below is documented as the owning thread's. A call from
 * anywhere else is refused with the reason rather than touching objects this
 * context does not own.
 */
bool nogui_capture_owns_thread(nogui_capture *cap) {
    return cap != nullptr && cap->thread_id == GetCurrentThreadId();
}

nogui_capture_status nogui_capture_wrong_thread(nogui_capture *cap) {
    cap->last_hresult = HRESULT_FROM_WIN32(ERROR_INVALID_THREAD);
    return NOGUI_CAPTURE_FAILED;
}

void nogui_capture_signal(nogui_capture *cap) {
    if (cap->frame_ready != nullptr) {
        SetEvent(cap->frame_ready);
    }
}

void nogui_capture_frame_arrived(nogui_capture *cap) {
    InterlockedExchange(&cap->frame_pending, 1);
    nogui_capture_signal(cap);
}

void nogui_capture_source_invalidated(nogui_capture *cap) {
    /*
     * The item was invalidated, which is how Windows reports a display change or a
     * policy change. The host learns from the next `next_frame` reporting
     * unavailable, so a callback on an arbitrary thread never mutates host state.
     */
    InterlockedExchange(&cap->frame_pending, -1);
    nogui_capture_signal(cap);
}

/*
 * Create the capture-only D3D11 device and its WinRT wrapper.
 *
 * `D3D11_CREATE_DEVICE_BGRA_SUPPORT` is the one creation flag the platform's own
 * capture samples pass; nothing else is asked for. A hardware driver is tried
 * first and the software rasterizer is a real second attempt: a machine with no
 * usable hardware adapter still captures a monitor, on the CPU.
 */
HRESULT nogui_capture_create_device(nogui_capture *cap) {
    static const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL obtained = D3D_FEATURE_LEVEL_11_0;

    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   flags, nullptr, 0, D3D11_SDK_VERSION,
                                   cap->device.put(), &obtained,
                                   cap->context.put());
    if (SUCCEEDED(hr)) {
        cap->driver = NOGUI_CAPTURE_DRIVER_HARDWARE;
    } else {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                               nullptr, 0, D3D11_SDK_VERSION, cap->device.put(),
                               &obtained, cap->context.put());
        if (SUCCEEDED(hr)) {
            cap->driver = NOGUI_CAPTURE_DRIVER_WARP;
        } else {
            cap->driver = NOGUI_CAPTURE_DRIVER_UNKNOWN;
            return hr;
        }
    }

    /*
     * The frame pool wants a `Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice`,
     * which is a different object from the `ID3D11Device` this context owns. The
     * documented bridge goes through DXGI.
     */
    ComPtr<IDXGIDevice> dxgi;
    hr = cap->device.As(dxgi.put());
    if (FAILED(hr)) {
        return hr;
    }
    return CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
                                               cap->winrt_device.put());
}

/*
 * Copies one D3D11 texture into a CPU buffer.
 *
 * The staging texture is the copy, and `Map` on it is what produces the bytes the
 * host publishes. Rows are copied one at a time through the mapped row pitch,
 * because that pitch is larger than `width * 4` on almost every adapter and
 * reading it as tightly packed would shear the image.
 */
nogui_capture_status nogui_capture_copy_texture(nogui_capture *cap,
                                                ID3D11Texture2D *texture,
                                                nogui_capture_owned_frame *out) {
    std::memset(out, 0, sizeof(*out));

    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);

    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
        desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM) {
        return NOGUI_CAPTURE_BAD_FORMAT;
    }
    if (desc.SampleDesc.Count > 1) {
        /*
         * A staging texture cannot be multisampled, and resolving into one is not
         * a documented destination, so a multisampled surface has no CPU-readable
         * equivalent here. Reported rather than copied wrongly.
         */
        return NOGUI_CAPTURE_BAD_FORMAT;
    }
    if (desc.Width == 0 || desc.Height == 0) {
        return NOGUI_CAPTURE_BAD_FORMAT;
    }

    if (cap->staging == nullptr || cap->staging_width != desc.Width ||
        cap->staging_height != desc.Height) {
        cap->staging.Reset();
        D3D11_TEXTURE2D_DESC staging = desc;
        staging.Usage = D3D11_USAGE_STAGING;
        staging.BindFlags = 0;
        staging.MiscFlags = 0;
        staging.SampleDesc.Count = 1;
        staging.SampleDesc.Quality = 0;
        HRESULT hr =
            cap->device->CreateTexture2D(&staging, nullptr, cap->staging.put());
        if (FAILED(hr)) {
            return nogui_capture_status_from(cap, hr);
        }
        cap->staging_width = desc.Width;
        cap->staging_height = desc.Height;
    }

    cap->context->CopyResource(cap->staging.Get(), texture);

    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr =
        cap->context->Map(cap->staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) {
        return nogui_capture_status_from(cap, hr);
    }

    const std::size_t size = static_cast<std::size_t>(mapped.RowPitch) *
                             static_cast<std::size_t>(desc.Height);
    unsigned char *data =
        static_cast<unsigned char *>(std::malloc(size == 0 ? 1 : size));
    if (data == nullptr) {
        cap->context->Unmap(cap->staging.Get(), 0);
        return nogui_capture_failed(cap, E_OUTOFMEMORY);
    }
    for (unsigned int row = 0; row < desc.Height; ++row) {
        std::memcpy(data + static_cast<std::size_t>(row) * mapped.RowPitch,
                    static_cast<const unsigned char *>(mapped.pData) +
                        static_cast<std::size_t>(row) * mapped.RowPitch,
                    mapped.RowPitch);
    }
    cap->context->Unmap(cap->staging.Get(), 0);

    out->data = data;
    out->size = size;
    out->stride = static_cast<unsigned int>(mapped.RowPitch);
    return NOGUI_CAPTURE_OK;
}

/* SystemRelativeTime is QPC-based, but TimeSpan.count() already uses 100 ns
 * units. Zero denotes an absent or unrepresentable host timestamp. */
unsigned long long nogui_capture_timestamp_ns(const Direct3D11CaptureFrame &frame) {
    const auto count = frame.SystemRelativeTime().count();
    if (count <= 0) {
        return 0;
    }
    const auto ticks = static_cast<unsigned long long>(count);
    if (ticks > (std::numeric_limits<unsigned long long>::max)() / 100ULL) {
        return 0;
    }
    return ticks * 100ULL;
}

} // namespace

extern "C" {

int nogui_capture_supported(void) {
    /*
     * `GraphicsCaptureSession::IsSupported` is the platform's documented own answer
     * to whether this machine can capture, which is a better question to ask than
     * whether a device can be created: a device is also what the renderer wants,
     * and the two are not the same capability.
     *
     * The call is a synchronous statics query, so it works on any thread. The
     * apartment is initialized and balanced here because the platform requires it
     * before any activation, and a host that asks on a thread with no runtime gets
     * an answer rather than an activation failure.
     */
    const HRESULT initialized = RoInitialize(RO_INIT_MULTITHREADED);
    const bool balance = SUCCEEDED(initialized);
    int supported = 0;
    try {
        supported = GraphicsCaptureSession::IsSupported() ? 1 : 0;
    } catch (...) {
        supported = 0;
    }
    if (balance) {
        RoUninitialize();
    }
    return supported;
}

nogui_capture_status nogui_capture_open(nogui_capture **out) {
    if (out == nullptr) {
        return NOGUI_CAPTURE_FAILED;
    }
    *out = nullptr;

    nogui_capture *cap = new (std::nothrow) nogui_capture();
    if (cap == nullptr) {
        return NOGUI_CAPTURE_FAILED;
    }

    const HRESULT initialized = RoInitialize(RO_INIT_MULTITHREADED);
    if (initialized == RPC_E_CHANGED_MODE) {
        /*
         * The thread is already in an apartment this path cannot use. Saying so
         * here is the honest answer: `nogui_capture_picker_wait` blocks the caller,
         * and a WinRT completion reaches a blocked single-threaded apartment only
         * while that apartment is pumping messages, which a blocking wait does not
         * do.
         */
        delete cap;
        return NOGUI_CAPTURE_UNAVAILABLE;
    }
    if (FAILED(initialized)) {
        delete cap;
        return NOGUI_CAPTURE_UNAVAILABLE;
    }
    cap->apartment_initialized = true;
    cap->thread_id = GetCurrentThreadId();

    cap->frame_ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (cap->frame_ready == nullptr) {
        cap->last_hresult = HRESULT_FROM_WIN32(GetLastError());
        nogui_capture_close(cap);
        return NOGUI_CAPTURE_FAILED;
    }

    try {
        if (!GraphicsCaptureSession::IsSupported()) {
            nogui_capture_close(cap);
            return NOGUI_CAPTURE_UNAVAILABLE;
        }
        const HRESULT hr = nogui_capture_create_device(cap);
        if (FAILED(hr)) {
            const nogui_capture_status status = nogui_capture_status_from(cap, hr);
            nogui_capture_close(cap);
            return status;
        }
    } catch (winrt::hresult_error const &error) {
        const nogui_capture_status status =
            nogui_capture_status_from(cap, error.code().value);
        nogui_capture_close(cap);
        return status;
    } catch (...) {
        nogui_capture_close(cap);
        return NOGUI_CAPTURE_FAILED;
    }

    *out = cap;
    return NOGUI_CAPTURE_OK;
}

void nogui_capture_close(nogui_capture *cap) {
    if (cap == nullptr) {
        return;
    }
    nogui_capture_stop(cap);
    if (cap->frame_ready != nullptr) {
        CloseHandle(cap->frame_ready);
        cap->frame_ready = nullptr;
    }
    if (cap->pick != nullptr) {
        try {
            cap->pick.Close();
        } catch (...) {
            /* An operation that is already finished has nothing to close. */
        }
        cap->pick = nullptr;
    }
    cap->session = nullptr;
    cap->item = nullptr;
    cap->pool = nullptr;
    cap->staging.Reset();
    cap->context.Reset();
    cap->device.Reset();
    cap->winrt_device.Reset();
    if (cap->apartment_initialized) {
        RoUninitialize();
    }
    delete cap;
}

nogui_capture_driver nogui_capture_driver_of(const nogui_capture *cap) {
    return cap == nullptr ? NOGUI_CAPTURE_DRIVER_UNKNOWN : cap->driver;
}

const char *nogui_capture_driver_name(const nogui_capture *cap) {
    switch (nogui_capture_driver_of(cap)) {
    case NOGUI_CAPTURE_DRIVER_HARDWARE:
        return "d3d11-hardware";
    case NOGUI_CAPTURE_DRIVER_WARP:
        return "d3d11-warp";
    default:
        return "none";
    }
}

long nogui_capture_last_hresult(const nogui_capture *cap) {
    return cap == nullptr ? 0 : static_cast<long>(cap->last_hresult);
}

nogui_capture_status nogui_capture_picker_show(nogui_capture *cap, void *hwnd) {
    if (!nogui_capture_owns_thread(cap)) {
        return nogui_capture_wrong_thread(cap);
    }
    /* A second pick while one is pending is refused rather than replacing the
     * pending answer, which would leave the first dialog's result unreachable. */
    if (cap->pick != nullptr) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
    try {
        GraphicsCapturePicker picker;
        /*
         * The picker is the OS's own dialog. This library does not choose what may
         * be captured, does not pre-approve anything, and does not substitute its
         * own UI. Parenting it to the host's window is the one thing the host
         * contributes, and a picker that cannot be parented is refused rather than
         * shown somewhere the user did not ask for.
         */
        if (hwnd != nullptr) {
            ComPtr<IInitializeWithWindow> parented;
            HRESULT hr = get_abi(picker).QueryInterface(
                IID_PPV_ARGS(parented.GetAddressOf()));
            if (FAILED(hr)) {
                return nogui_capture_status_from(cap, hr);
            }
            hr = parented->Initialize(static_cast<HWND>(hwnd));
            if (FAILED(hr)) {
                return nogui_capture_status_from(cap, hr);
            }
        }
        cap->pick = picker.PickSingleItemAsync();
    } catch (winrt::hresult_error const &error) {
        return nogui_capture_status_from(cap, error.code().value);
    } catch (...) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
    return NOGUI_CAPTURE_OK;
}

/*
 * Read the pending pick without waiting. `out_item` is only written on success, and
 * the item it hands over is one reference the caller owns and releases.
 */
nogui_capture_status nogui_capture_picker_poll(nogui_capture *cap, void **out_item) {
    if (!nogui_capture_owns_thread(cap)) {
        return nogui_capture_wrong_thread(cap);
    }
    if (out_item == nullptr) {
        return nogui_capture_failed(cap, E_POINTER);
    }
    *out_item = nullptr;
    if (cap->pick == nullptr) {
        /* No pick was ever started, so there is no answer to report and nothing was
         * asked of the user. */
        return NOGUI_CAPTURE_CANCELED;
    }
    try {
        AsyncStatus status = AsyncStatus::Started;
        try {
            status = cap->pick.Status();
        } catch (winrt::hresult_error const &error) {
            return nogui_capture_status_from(cap, error.code().value);
        }
        switch (status) {
        case AsyncStatus::Completed: {
            GraphicsCaptureItem chosen = cap->pick.GetResults();
            *out_item = chosen.detach();
            return NOGUI_CAPTURE_OK;
        }
        case AsyncStatus::Canceled:
            /* The user closed the picker with no selection. */
            return NOGUI_CAPTURE_CANCELED;
        case AsyncStatus::Error: {
            HRESULT reason = S_OK;
            try {
                cap->pick.GetResults();
            } catch (winrt::hresult_error const &error) {
                reason = error.code().value;
            }
            /* A closed picker and a refused one are different answers and the host
             * contract keeps them apart, so the status is chosen here rather than
             * flattened. */
            return nogui_capture_status_from(cap, reason);
        }
        default:
            return NOGUI_CAPTURE_FAILED;
        }
    } catch (winrt::hresult_error const &error) {
        return nogui_capture_status_from(cap, error.code().value);
    } catch (...) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
}

nogui_capture_status nogui_capture_picker_wait(nogui_capture *cap, int timeout_ms,
                                               void **out_item) {
    if (!nogui_capture_owns_thread(cap)) {
        return nogui_capture_wrong_thread(cap);
    }
    if (out_item == nullptr) {
        return nogui_capture_failed(cap, E_POINTER);
    }
    *out_item = nullptr;
    if (cap->pick == nullptr) {
        return NOGUI_CAPTURE_CANCELED;
    }

    /*
     * The status is polled on a short timer until it leaves Started. That is the
     * one way to observe the operation from a caller that is blocked rather than
     * pumping: a WinRT completion reaches this thread through the thread pool,
     * which happens without this thread pumping anything.
     */
    const DWORD limit_ms =
        timeout_ms < 0 ? INFINITE : static_cast<DWORD>(timeout_ms);
    DWORD waited = 0;
    try {
        for (;;) {
            if (cap->pick.Status() != AsyncStatus::Started) {
                break;
            }
            if (limit_ms != INFINITE && waited >= limit_ms) {
                return NOGUI_CAPTURE_TIMEOUT;
            }
            Sleep(k_pick_poll_ms);
            if (limit_ms != INFINITE) {
                waited += k_pick_poll_ms;
            }
        }
    } catch (winrt::hresult_error const &error) {
        return nogui_capture_status_from(cap, error.code().value);
    } catch (...) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
    return nogui_capture_picker_poll(cap, out_item);
}

void nogui_capture_item_destroy(void *item) {
    if (item == nullptr) {
        return;
    }
    static_cast<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem *>(item)
        ->Release();
}

nogui_capture_status nogui_capture_start(nogui_capture *cap, void *item,
                                         unsigned int width, unsigned int height) {
    if (!nogui_capture_owns_thread(cap)) {
        return nogui_capture_wrong_thread(cap);
    }
    if (item == nullptr) {
        return nogui_capture_failed(cap, E_INVALIDARG);
    }
    if (cap->device == nullptr || cap->context == nullptr ||
        cap->winrt_device == nullptr) {
        return nogui_capture_unavailable(cap, E_UNEXPECTED);
    }
    nogui_capture_stop(cap);

    try {
        GraphicsCaptureItem source{
            static_cast<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem *>(
                item)};
        /* One reference of our own, so the item survives the caller's release for
         * as long as this session needs it. */
        cap->item = source.clone();

        SizeInt32 size = cap->item.Size();
        if (width != 0 && height != 0) {
            size.Width = static_cast<int32_t>(width);
            size.Height = static_cast<int32_t>(height);
        }
        if (size.Width <= 0 || size.Height <= 0) {
            nogui_capture_stop(cap);
            return nogui_capture_failed(cap, E_INVALIDARG);
        }

        cap->pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            cap->winrt_device.Get(),
            DirectXPixelFormat::B8G8R8A8UIntNormalized, k_pool_buffer_count, size);
        /*
         * `CreateCaptureSession` is a method on the pool, and it is the only way to
         * make a session for an item.
         */
        cap->session = cap->pool.CreateCaptureSession(cap->item);

        InterlockedExchange(&cap->frame_pending, 0);
        if (cap->frame_ready != nullptr) {
            ResetEvent(cap->frame_ready);
        }

        cap->frame_token = cap->pool.FrameArrived(
            [cap](Direct3D11CaptureFramePool const &, IInspectable const &) {
                nogui_capture_frame_arrived(cap);
            });
        /* Invalidation is reported on the item, not on the session. */
        cap->closed_token = cap->item.Closed(
            [cap](GraphicsCaptureItem const &, IInspectable const &) {
                nogui_capture_source_invalidated(cap);
            });

        cap->session.StartCapture();
    } catch (winrt::hresult_error const &error) {
        const HRESULT hr = error.code().value;
        const nogui_capture_status status = nogui_capture_status_from(cap, hr);
        nogui_capture_stop(cap);
        return status;
    } catch (...) {
        nogui_capture_stop(cap);
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
    return NOGUI_CAPTURE_OK;
}

void nogui_capture_stop(nogui_capture *cap) {
    if (cap == nullptr) {
        return;
    }
    if (cap->pool != nullptr && cap->frame_token.value != 0) {
        try {
            cap->pool.FrameArrived(cap->frame_token);
        } catch (...) {
            /* A pool that is already closed has nothing to remove. */
        }
        cap->frame_token = winrt::event_token{};
    }
    if (cap->item != nullptr && cap->closed_token.value != 0) {
        try {
            cap->item.Closed(cap->closed_token);
        } catch (...) {
            /* An item that is already gone has nothing to remove. */
        }
        cap->closed_token = winrt::event_token{};
    }
    if (cap->session != nullptr) {
        try {
            cap->session.Close();
        } catch (...) {
            /* Closing twice is the shell's business, not ours. */
        }
        cap->session = nullptr;
    }
    cap->item = nullptr;
    if (cap->pool != nullptr) {
        try {
            cap->pool.Close();
        } catch (...) {
            /* As above. */
        }
        cap->pool = nullptr;
    }
    cap->staging.Reset();
    cap->staging_width = 0;
    cap->staging_height = 0;
    InterlockedExchange(&cap->frame_pending, 0);
}

nogui_capture_status nogui_capture_next_frame(nogui_capture *cap,
                                              nogui_capture_frame *out,
                                              int timeout_ms) {
    if (!nogui_capture_owns_thread(cap)) {
        return nogui_capture_wrong_thread(cap);
    }
    if (out == nullptr) {
        return nogui_capture_failed(cap, E_POINTER);
    }
    std::memset(out, 0, sizeof(*out));
    if (cap->pool == nullptr || cap->frame_ready == nullptr) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }

    const DWORD waited = WaitForSingleObject(
        cap->frame_ready,
        timeout_ms < 0 ? INFINITE : static_cast<DWORD>(timeout_ms));
    if (waited == WAIT_TIMEOUT) {
        return NOGUI_CAPTURE_TIMEOUT;
    }
    if (waited != WAIT_OBJECT_0) {
        return nogui_capture_failed(cap, HRESULT_FROM_WIN32(GetLastError()));
    }
    if (InterlockedExchange(&cap->frame_pending, 0) < 0) {
        /* The source was invalidated between frames. The contract has a name for a
         * stream that went away on its own. */
        return NOGUI_CAPTURE_UNAVAILABLE;
    }

    try {
        Direct3D11CaptureFrame frame{nullptr};
        if (!cap->pool.TryGetNextFrame(frame) || frame == nullptr) {
            /* The documented benign case: the frame was already taken, or the
             * buffer is not ready. That is a timeout, not a failure. */
            return NOGUI_CAPTURE_TIMEOUT;
        }

        /* The surface stays alive across the interface query below, so its
         * reference is held by a local and not by a temporary that ends with the
         * statement. */
        auto surface = frame.Surface();
        ComPtr<IDirect3DDxgiInterfaceAccess> access;
        HRESULT hr = get_abi(surface).QueryInterface(
            IID_PPV_ARGS(access.GetAddressOf()));
        if (FAILED(hr)) {
            return nogui_capture_status_from(cap, hr);
        }
        ComPtr<ID3D11Texture2D> texture;
        hr = access->GetInterface(IID_PPV_ARGS(texture.GetAddressOf()));
        if (FAILED(hr)) {
            return nogui_capture_status_from(cap, hr);
        }

        nogui_capture_owned_frame copied{};
        const nogui_capture_status status =
            nogui_capture_copy_texture(cap, texture.Get(), &copied);
        if (status != NOGUI_CAPTURE_OK) {
            /* An unreadable frame is gone before this returns, so a failure here
             * leaves nothing outstanding. */
            return status;
        }

        const unsigned long long timestamp = nogui_capture_timestamp_ns(frame);

        nogui_capture_owned_frame *owner = static_cast<nogui_capture_owned_frame *>(
            std::malloc(sizeof(nogui_capture_owned_frame)));
        if (owner == nullptr) {
            SecureZeroMemory(copied.data, copied.size);
            std::free(copied.data);
            return nogui_capture_failed(cap, E_OUTOFMEMORY);
        }
        /*
         * The platform frame goes back to the pool here, as soon as the copy is
         * complete. What the host reads afterwards is the CPU buffer, which belongs
         * to nobody else, so there is nothing left to keep alive and a release is
         * one wipe and one free.
         */
        owner->data = copied.data;
        owner->size = copied.size;
        owner->stride = copied.stride;

        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);

        out->data = copied.data;
        out->width = desc.Width;
        out->height = desc.Height;
        out->stride = copied.stride;
        out->format = desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM ? 1u : 0u;
        out->timestamp_ns = timestamp;
        out->owner = owner;
    } catch (winrt::hresult_error const &error) {
        return nogui_capture_status_from(cap, error.code().value);
    } catch (...) {
        return nogui_capture_failed(cap, E_UNEXPECTED);
    }
    return NOGUI_CAPTURE_OK;
}

void nogui_capture_frame_release(nogui_capture_frame *frame) {
    if (frame == nullptr) {
        return;
    }
    auto *owner = static_cast<nogui_capture_owned_frame *>(frame->owner);
    if (owner != nullptr) {
        if (owner->data != nullptr) {
            /*
             * The bytes are a capture of the user's screen, so they are wiped
             * rather than merely freed. A freed block stays readable in the heap
             * until something overwrites it by accident.
             */
            SecureZeroMemory(owner->data, owner->size);
            std::free(owner->data);
        }
        std::free(owner);
    }
    /* Zeroed on the way out, so a second release reads an empty descriptor and does
     * nothing rather than freeing the same block twice. */
    std::memset(frame, 0, sizeof(*frame));
}

} // extern "C"
