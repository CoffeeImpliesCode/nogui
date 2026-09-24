/*
 * The Windows toast notification platform, behind a narrow C ABI.
 *
 * Every SDK call here is spelled the way the Windows SDK declares it and no
 * projection is used, because a C build has no C++/WinRT. The interface
 * declarations come from the SDK headers themselves, so a wrong IID or a wrong
 * method order is a link error or a runtime HRESULT rather than a silent success
 * against the wrong object.
 *
 * The chain, all of it inbox SDK:
 *
 *   IToastNotificationManagerStatics  CreateToastNotifierWithId  (binds the identity)
 *   IToastNotifier                    get_Setting, Show, Hide
 *   IToastNotificationFactory         CreateToastNotification   (from an XmlDocument)
 *   IToastNotification2               put_Tag, put_Group
 *   IToastNotificationManagerStatics2 get_History               (Action Center)
 *   IToastNotificationHistory         RemoveGroupedTagWithId
 *
 * plus the XML document pair from `Windows.Data.Xml.Dom`:
 *
 *   IXmlDocument                       the object a toast holds as content
 *   IXmlDocumentIO                     LoadXml
 *
 * and `INotificationActivationCallback` from `notificationactivationcallback.h` for
 * the shell's activation call. Three names that are easy to get wrong: the notifier
 * is created with `CreateToastNotifierWithId` and not with the argument-less
 * overload, which the platform documents as the wrong one for a desktop app; the
 * toast itself has no constructor and comes from `IToastNotificationFactory`; and
 * removal is not a method on the manager at all but a method on the history object
 * that the manager's `Statics2` interface returns.
 *
 * Release order is the part that has to be right, because a toast holds a
 * reference to its content document and the document holds the parsed tree. Every
 * exit releases exactly what it acquired, which is why each block pairs its acquire
 * with its release instead of collecting them at the end.
 *
 * Threading: the toast classes are documented as multithreaded and agile, and this
 * file creates and destroys every object inside one call, so any thread may call
 * it. The activation handler is the exception the platform imposes: the shell
 * calls it on a COM thread of its choosing, and the handler only copies bytes into
 * the caller's own structure before returning.
 *
 * Threading, second half: a COM thread runs the handler, and the host thread can
 * unregister while that handler is already inside it. So a callback context is
 * owned by the registration until `nogui_toast_activator_unregister` returns:
 * the handler counts itself before it calls the context and gives the count back
 * after, the unregister waits for the count, and the caller may free the context
 * as soon as the call returns. Every path here is written so that promise holds:
 * the handler runs with no lock held, the revocation runs with no lock held, and
 * the wait is a condition variable rather than a spin.
 */
#include "nogui_toast.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
/* The C runtime warns about the two of its unchecked functions this file uses,
 * both of which are called with an explicit size. */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include <windows.h>

#include <objbase.h>
#include <roapi.h>
#include <winreg.h>

#include <notificationactivationcallback.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* The runtime class names, as `RoGetActivationFactory` and `RoActivateInstance`
 * name them. */
static const wchar_t *const kToastManagerClass =
    L"Windows.UI.Notifications.ToastNotificationManager";
static const wchar_t *const kToastClass =
    L"Windows.UI.Notifications.ToastNotification";
static const wchar_t *const kXmlDocumentClass =
    L"Windows.Data.Xml.Dom.XmlDocument";

/* The platform's documented limit on a toast tag, extended by the Creators
 * Update. A longer tag is refused rather than truncated, because a truncated tag is
 * a different identity from the one the host asked for. */
#define NOGUI_TOAST_TAG_LIMIT 64

/* The per-user COM registration root, where a desktop toast's activator lives. */
static const wchar_t *const kClassesRoot = L"Software\\Classes\\CLSID";

/*
 * The balance of `RoInitialize` on this thread, which the runtime keeps per
 * thread and the caller must honour. A nested init, or one on a thread that already
 * had the runtime, still counts as one this library owns, because a host that
 * initialized WinRT for its own reasons must not have it torn down by a toast.
 */
static __declspec(thread) LONG g_runtime_depth = 0;

static nogui_toast_status nogui_toast_from_hresult(HRESULT hr) {
    if (SUCCEEDED(hr)) {
        return NOGUI_TOAST_OK;
    }
    if (hr == REGDB_E_CLASSNOTREG || hr == CLASS_E_CLASSNOTAVAILABLE ||
        hr == RO_E_CLOSED || hr == CO_E_CLASSSTRING ||
        hr == HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)) {
        /*
         * No app model identity the shell will attribute a toast to, or no
         * notification platform behind it. Neither is a retry.
         */
        return NOGUI_TOAST_UNAVAILABLE;
    }
    if (hr == E_ACCESSDENIED || hr == E_ABORT ||
        hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)) {
        /* The platform answered and its answer was no. */
        return NOGUI_TOAST_DENIED;
    }
    if (hr == E_INVALIDARG) {
        return NOGUI_TOAST_INVALID;
    }
    return NOGUI_TOAST_FAILED;
}

/* Make a `HSTRING` from a NUL-terminated wide string, or report the failure. */
static HRESULT nogui_toast_hstring(const wchar_t *text, HSTRING *out) {
    *out = NULL;
    return WindowsCreateString(text, (UINT32)wcslen(text), out);
}

int nogui_toast_runtime_init(void) {
    /*
     * The toast classes are documented as multithreaded and agile, so the runtime
     * is initialized for the multithreaded apartment. `RoInitialize` is reference
     * counted per thread, which is why a nested call still returns 1 and still owes
     * a balance.
     */
    if (g_runtime_depth > 0) {
        g_runtime_depth += 1;
        return 1;
    }
    HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
    if (hr == RPC_E_CHANGED_MODE) {
        /*
         * The thread already chose another apartment. That is a usable runtime, so
         * the host proceeds; the mismatch is not this library's to fix, and
         * reporting failure would break a host that already works. It owns no
         * balance, so it returns 0.
         */
        return 0;
    }
    if (FAILED(hr)) {
        return -1;
    }
    g_runtime_depth = 1;
    return 1;
}

void nogui_toast_runtime_uninit(void) {
    if (g_runtime_depth > 0) {
        g_runtime_depth -= 1;
        if (g_runtime_depth == 0) {
            RoUninitialize();
        }
    }
}

/* The statics object the notifier and the history both come from. */
static IToastNotificationManagerStatics *nogui_toast_manager_statics(void) {
    IToastNotificationManagerStatics *statics = NULL;
    HSTRING name = NULL;
    if (FAILED(nogui_toast_hstring(kToastManagerClass, &name))) {
        return NULL;
    }
    const HRESULT hr = RoGetActivationFactory(
        name, &IID_IToastNotificationManagerStatics, (void **)&statics);
    WindowsDeleteString(name);
    if (FAILED(hr)) {
        return NULL;
    }
    return statics;
}

/*
 * The notifier for one AppUserModelID, or null.
 *
 * `CreateToastNotifierWithId` is the overload the platform documents for a desktop
 * app: the identity it takes is the `System.AppUserModel.ID` of a Start menu
 * shortcut, and the argument-less overload is documented as the wrong one.
 */
static IToastNotifier *nogui_toast_notifier(const wchar_t *app_id) {
    IToastNotificationManagerStatics *statics = nogui_toast_manager_statics();
    if (statics == NULL) {
        return NULL;
    }
    HSTRING identity = NULL;
    if (FAILED(nogui_toast_hstring(app_id, &identity))) {
        statics->lpVtbl->Release(statics);
        return NULL;
    }
    IToastNotifier *notifier = NULL;
    const HRESULT hr = statics->lpVtbl->CreateToastNotifierWithId(
        statics, identity, &notifier);
    WindowsDeleteString(identity);
    statics->lpVtbl->Release(statics);
    if (FAILED(hr)) {
        return NULL;
    }
    return notifier;
}

/* The platform's own answer to whether this identity may show toasts. */
static nogui_toast_blocker nogui_toast_setting_of(IToastNotifier *notifier) {
    NotificationSetting setting = NotificationSetting_Enabled;
    if (FAILED(notifier->lpVtbl->get_Setting(notifier, &setting))) {
        /* A platform that will not say is not a platform saying yes. */
        return NOGUI_TOAST_BLOCKER_DISABLED_FOR_APPLICATION;
    }
    switch (setting) {
    case NotificationSetting_Enabled:
        return NOGUI_TOAST_BLOCKER_NONE;
    case NotificationSetting_DisabledForApplication:
        return NOGUI_TOAST_BLOCKER_DISABLED_FOR_APPLICATION;
    case NotificationSetting_DisabledForUser:
        return NOGUI_TOAST_BLOCKER_DISABLED_FOR_USER;
    case NotificationSetting_DisabledByGroupPolicy:
        return NOGUI_TOAST_BLOCKER_DISABLED_BY_GROUP_POLICY;
    case NotificationSetting_DisabledByManifest:
        return NOGUI_TOAST_BLOCKER_DISABLED_BY_MANIFEST;
    default:
        return NOGUI_TOAST_BLOCKER_DISABLED_FOR_APPLICATION;
    }
}

nogui_toast_status nogui_toast_probe(const wchar_t *app_id,
                                     nogui_toast_probe_result *out) {
    if (out != NULL) {
        memset(out, 0, sizeof(*out));
    }
    if (app_id == NULL || app_id[0] == L'\0') {
        return NOGUI_TOAST_INVALID;
    }
    IToastNotifier *notifier = nogui_toast_notifier(app_id);
    if (notifier == NULL) {
        return NOGUI_TOAST_UNAVAILABLE;
    }
    const nogui_toast_blocker blocker = nogui_toast_setting_of(notifier);
    notifier->lpVtbl->Release(notifier);
    if (out != NULL) {
        out->blocker = blocker;
        out->can_show = (blocker == NOGUI_TOAST_BLOCKER_NONE) ? 1 : 0;
    }
    /* A notifier that exists but is switched off is a refusal by policy or by the
     * user, not a platform that is missing. */
    return (blocker == NOGUI_TOAST_BLOCKER_NONE) ? NOGUI_TOAST_OK
                                                 : NOGUI_TOAST_DENIED;
}

/*
 * Build an `IXmlDocument` from the host's XML text.
 *
 * The document is activated first and then asked for its IO interface, which is
 * the only order the SDK supports: `XmlDocument` is activatable and
 * `IXmlDocumentIO` is a separate interface on the same object that owns `LoadXml`.
 */
static nogui_toast_status nogui_toast_document(const wchar_t *xml,
                                               IXmlDocument **out_document) {
    *out_document = NULL;
    HSTRING name = NULL;
    if (FAILED(nogui_toast_hstring(kXmlDocumentClass, &name))) {
        return NOGUI_TOAST_FAILED;
    }
    IInspectable *raw = NULL;
    HRESULT hr = RoActivateInstance(name, &raw);
    WindowsDeleteString(name);
    if (FAILED(hr)) {
        return nogui_toast_from_hresult(hr);
    }
    IXmlDocument *document = NULL;
    hr = raw->lpVtbl->QueryInterface(raw, &IID_IXmlDocument, (void **)&document);
    raw->lpVtbl->Release(raw);
    if (FAILED(hr)) {
        return nogui_toast_from_hresult(hr);
    }
    IXmlDocumentIO *io = NULL;
    hr = document->lpVtbl->QueryInterface(document, &IID_IXmlDocumentIO,
                                          (void **)&io);
    if (FAILED(hr)) {
        document->lpVtbl->Release(document);
        return nogui_toast_from_hresult(hr);
    }
    HSTRING text = NULL;
    hr = nogui_toast_hstring(xml, &text);
    if (FAILED(hr)) {
        io->lpVtbl->Release(io);
        document->lpVtbl->Release(document);
        return NOGUI_TOAST_FAILED;
    }
    hr = io->lpVtbl->LoadXml(io, text);
    /* The parsed tree is held by the document, not by the IO interface or by the
     * string, so the string goes as soon as the call returns. */
    WindowsDeleteString(text);
    io->lpVtbl->Release(io);
    if (FAILED(hr)) {
        document->lpVtbl->Release(document);
        /* A rejected document is the caller's XML, not a platform refusal, so it
         * is reported as invalid rather than failed. */
        return NOGUI_TOAST_INVALID;
    }
    *out_document = document;
    return NOGUI_TOAST_OK;
}

/*
 * The toasts this library still holds a reference to, so a dismissal can retract a
 * banner with `IToastNotifier::Hide` instead of only clearing history.
 *
 * Bounded on purpose: a host that shows many toasts and dismisses none must not
 * grow this table, because every entry keeps a toast alive. The oldest entry is
 * released when the table is full, and a dismissal of an evicted toast then only
 * clears history, which is what the platform allows.
 */
#define NOGUI_TOAST_HELD 8

typedef struct nogui_toast_held {
    wchar_t *tag;
    wchar_t *group;
    IToastNotification *toast;
} nogui_toast_held;

static nogui_toast_held g_held[NOGUI_TOAST_HELD];
static LONG g_held_next = 0;

/*
 * One lock for the two pieces of process-wide state: the toasts still held for a
 * possible `Hide`, and the activation callback. It is created once through
 * `InitOnceExecuteOnce`, because initializing a live critical section again is
 * undefined and two threads can be the first caller at once.
 *
 * `g_drained` is the matching condition variable. It is what turns retiring the
 * activation callback into a barrier rather than a flag: an unregister waits on
 * it for the activations that had already taken the callback, instead of
 * spinning on a counter or handing the caller a promise it has to keep.
 */
static INIT_ONCE g_lock_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_lock;
static CONDITION_VARIABLE g_drained;

static BOOL CALLBACK nogui_toast_init_lock(PINIT_ONCE once, PVOID parameter,
                                          PVOID *context) {
    (void)once;
    (void)parameter;
    (void)context;
    InitializeCriticalSection(&g_lock);
    /* Created by the same one-shot call, because waiting on it needs the lock
     * this call creates. */
    InitializeConditionVariable(&g_drained);
    return TRUE;
}

static void nogui_toast_lock(void) {
    (void)InitOnceExecuteOnce(&g_lock_once, nogui_toast_init_lock, NULL, NULL);
    EnterCriticalSection(&g_lock);
}

static void nogui_toast_unlock(void) {
    LeaveCriticalSection(&g_lock);
}

static void nogui_toast_held_release(nogui_toast_held *slot) {
    if (slot->toast != NULL) {
        slot->toast->lpVtbl->Release(slot->toast);
        slot->toast = NULL;
    }
    free(slot->tag);
    slot->tag = NULL;
    free(slot->group);
    slot->group = NULL;
}

/* Take a copy of a wide string, or null when there is nothing to copy. */
static wchar_t *nogui_toast_copy(const wchar_t *text) {
    if (text == NULL || text[0] == L'\0') {
        return NULL;
    }
    const size_t count = wcslen(text) + 1;
    wchar_t *copy = (wchar_t *)malloc(count * sizeof(wchar_t));
    if (copy != NULL) {
        memcpy(copy, text, count * sizeof(wchar_t));
    }
    return copy;
}

/* Remember a toast so a later dismissal can retract its banner. */
static void nogui_toast_hold(const wchar_t *tag, const wchar_t *group,
                             IToastNotification *toast) {
    if (tag == NULL || toast == NULL) {
        return;
    }
    nogui_toast_lock();
    nogui_toast_held *slot = &g_held[(unsigned int)g_held_next % NOGUI_TOAST_HELD];
    g_held_next += 1;
    nogui_toast_held_release(slot);
    slot->tag = nogui_toast_copy(tag);
    slot->group = nogui_toast_copy(group);
    toast->lpVtbl->AddRef(toast);
    slot->toast = toast;
    nogui_toast_unlock();
}

/* Take a held toast by tag and group out of the table, or find none. */
static IToastNotification *nogui_toast_take(const wchar_t *tag,
                                            const wchar_t *group) {
    IToastNotification *found = NULL;
    if (tag == NULL) {
        return NULL;
    }
    nogui_toast_lock();
    for (int index = 0; index < NOGUI_TOAST_HELD; index += 1) {
        nogui_toast_held *slot = &g_held[index];
        if (slot->toast != NULL && slot->tag != NULL &&
            _wcsicmp(slot->tag, tag) == 0 &&
            ((slot->group == NULL && group == NULL) ||
             (slot->group != NULL && group != NULL &&
              _wcsicmp(slot->group, group) == 0))) {
            found = slot->toast;
            slot->toast = NULL;
            nogui_toast_held_release(slot);
            break;
        }
    }
    nogui_toast_unlock();
    return found;
}

nogui_toast_status nogui_toast_show(const wchar_t *app_id, const wchar_t *xml,
                                    const wchar_t *tag, const wchar_t *group) {
    if (app_id == NULL || app_id[0] == L'\0' || xml == NULL || xml[0] == L'\0') {
        return NOGUI_TOAST_INVALID;
    }
    /*
     * A tag is what makes a later dismissal possible, and the platform rejects an
     * empty one, so an empty tag is a caller mistake rather than a toast without
     * identity. A tag past the documented limit is refused rather than truncated: a
     * truncated tag is a different identity from the one the host asked for.
     */
    if (tag != NULL && wcslen(tag) > NOGUI_TOAST_TAG_LIMIT) {
        return NOGUI_TOAST_INVALID;
    }
    if (group != NULL && wcslen(group) > NOGUI_TOAST_TAG_LIMIT) {
        return NOGUI_TOAST_INVALID;
    }

    IToastNotifier *notifier = nogui_toast_notifier(app_id);
    if (notifier == NULL) {
        return NOGUI_TOAST_UNAVAILABLE;
    }
    if (nogui_toast_setting_of(notifier) != NOGUI_TOAST_BLOCKER_NONE) {
        /* Switched off by manifest, policy, user or application: the platform
         * answered, and its answer was no. */
        notifier->lpVtbl->Release(notifier);
        return NOGUI_TOAST_DENIED;
    }

    IXmlDocument *document = NULL;
    const nogui_toast_status status = nogui_toast_document(xml, &document);
    if (status != NOGUI_TOAST_OK) {
        notifier->lpVtbl->Release(notifier);
        return status;
    }

    IToastNotification *toast = NULL;
    IToastNotificationFactory *factory = NULL;
    HSTRING name = NULL;
    if (FAILED(nogui_toast_hstring(kToastClass, &name))) {
        document->lpVtbl->Release(document);
        notifier->lpVtbl->Release(notifier);
        return NOGUI_TOAST_FAILED;
    }
    HRESULT hr = RoGetActivationFactory(name, &IID_IToastNotificationFactory,
                                        (void **)&factory);
    WindowsDeleteString(name);
    if (FAILED(hr)) {
        document->lpVtbl->Release(document);
        notifier->lpVtbl->Release(notifier);
        return nogui_toast_from_hresult(hr);
    }
    hr = factory->lpVtbl->CreateToastNotification(factory, document, &toast);
    factory->lpVtbl->Release(factory);
    /* The toast holds its own reference to the document now, so the document is
     * released here and the toast is what keeps the parsed tree alive. */
    document->lpVtbl->Release(document);
    if (FAILED(hr)) {
        notifier->lpVtbl->Release(notifier);
        return nogui_toast_from_hresult(hr);
    }

    /* Tag and group are set through `IToastNotification2`, a later interface on the
     * same object, and before `Show`, because `Show` is the only call that hands
     * the toast to the shell. */
    IToastNotification2 *tagged = NULL;
    hr = toast->lpVtbl->QueryInterface(toast, &IID_IToastNotification2,
                                       (void **)&tagged);
    if (SUCCEEDED(hr)) {
        if (tag != NULL && tag[0] != L'\0') {
            HSTRING value = NULL;
            hr = nogui_toast_hstring(tag, &value);
            if (SUCCEEDED(hr)) {
                hr = tagged->lpVtbl->put_Tag(tagged, value);
                /* The toast copies the string, so it goes immediately. */
                WindowsDeleteString(value);
            }
        }
        if (SUCCEEDED(hr) && group != NULL && group[0] != L'\0') {
            HSTRING value = NULL;
            hr = nogui_toast_hstring(group, &value);
            if (SUCCEEDED(hr)) {
                hr = tagged->lpVtbl->put_Group(tagged, value);
                WindowsDeleteString(value);
            }
        }
        tagged->lpVtbl->Release(tagged);
    }
    if (FAILED(hr)) {
        toast->lpVtbl->Release(toast);
        notifier->lpVtbl->Release(notifier);
        return nogui_toast_from_hresult(hr);
    }

    hr = notifier->lpVtbl->Show(notifier, toast);
    if (FAILED(hr)) {
        toast->lpVtbl->Release(toast);
        notifier->lpVtbl->Release(notifier);
        return nogui_toast_from_hresult(hr);
    }
    /* `Show` returns once the shell has the toast and the object outlives the
     * call, so a reference is kept for a possible `Hide`. */
    nogui_toast_hold(tag, group, toast);
    toast->lpVtbl->Release(toast);
    notifier->lpVtbl->Release(notifier);
    return NOGUI_TOAST_OK;
}

nogui_toast_status nogui_toast_remove(const wchar_t *app_id, const wchar_t *tag,
                                      const wchar_t *group) {
    if (app_id == NULL || app_id[0] == L'\0' || tag == NULL || tag[0] == L'\0') {
        /*
         * A toast with no tag cannot be named, and that is the whole reason a
         * dismissal of one is refused instead of silently succeeding.
         */
        return NOGUI_TOAST_INVALID;
    }

    /* A banner this library still holds is retracted first, because removing a
     * toast from Action Center does not take away a banner that is already on
     * screen. */
    IToastNotification *held = nogui_toast_take(tag, group);
    if (held != NULL) {
        IToastNotifier *notifier = nogui_toast_notifier(app_id);
        if (notifier != NULL) {
            notifier->lpVtbl->Hide(notifier, held);
            notifier->lpVtbl->Release(notifier);
        }
        held->lpVtbl->Release(held);
    }

    /* Then the history entry, through the history object that the manager's
     * `Statics2` interface returns, because the manager itself has no removal
     * method. */
    IToastNotificationManagerStatics2 *statics = NULL;
    HSTRING name = NULL;
    if (FAILED(nogui_toast_hstring(kToastManagerClass, &name))) {
        return NOGUI_TOAST_FAILED;
    }
    HRESULT hr = RoGetActivationFactory(
        name, &IID_IToastNotificationManagerStatics2, (void **)&statics);
    WindowsDeleteString(name);
    if (FAILED(hr)) {
        /* Without this interface the platform has no per-tag history, so a
         * dismissal is unavailable rather than failed. */
        return NOGUI_TOAST_UNAVAILABLE;
    }
    IToastNotificationHistory *history = NULL;
    hr = statics->lpVtbl->get_History(statics, &history);
    statics->lpVtbl->Release(statics);
    if (FAILED(hr)) {
        return nogui_toast_from_hresult(hr);
    }

    HSTRING identity = NULL;
    HSTRING tag_value = NULL;
    HSTRING group_value = NULL;
    hr = nogui_toast_hstring(app_id, &identity);
    if (SUCCEEDED(hr)) {
        hr = nogui_toast_hstring(tag, &tag_value);
    }
    if (SUCCEEDED(hr)) {
        hr = nogui_toast_hstring(group != NULL ? group : L"", &group_value);
    }
    if (FAILED(hr)) {
        if (identity != NULL) {
            WindowsDeleteString(identity);
        }
        if (tag_value != NULL) {
            WindowsDeleteString(tag_value);
        }
        if (group_value != NULL) {
            WindowsDeleteString(group_value);
        }
        history->lpVtbl->Release(history);
        return NOGUI_TOAST_FAILED;
    }
    hr = history->lpVtbl->RemoveGroupedTagWithId(history, tag_value, group_value,
                                                 identity);
    WindowsDeleteString(group_value);
    WindowsDeleteString(tag_value);
    WindowsDeleteString(identity);
    history->lpVtbl->Release(history);
    return nogui_toast_from_hresult(hr);
}

/* --- the COM activation handler ------------------------------------------ */

/*
 * The activation object.
 *
 * Implementing a COM interface in C means writing its table: the SDK's
 * `INotificationActivationCallback` declares the interface and its one method, and
 * the table below supplies the three `IUnknown` slots plus that method with the
 * signature the SDK states. There is no other slot, so there is nothing to guess
 * about the layout.
 */
typedef struct nogui_toast_activator_vtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(void *);
    ULONG(STDMETHODCALLTYPE *Release)(void *);
    HRESULT(STDMETHODCALLTYPE *Activate)(void *, LPCWSTR, LPCWSTR,
                                         const NOTIFICATION_USER_INPUT_DATA *, ULONG);
} nogui_toast_activator_vtbl;

/*
 * The class object itself: a vtable pointer and a count, and nothing else.
 *
 * There is one of these per process, in static storage, and there is never a
 * second one to reconcile. `Activate` holds no registration state of its own --
 * it reads the callback and the context from the table below -- so every
 * registration this process makes hands COM this same object, and the object
 * outlives all of them by construction.
 *
 * That outliving is the point. COM holds a reference of its own from
 * `CoRegisterClassObject` until the revoke, and a shell thread that took an
 * interface reference just before a revocation may still call through it
 * afterwards, so the object a stale call would land on must not be freed with
 * the cookie. Static storage and a permanent reference make that a property of
 * the type instead of a rule someone has to remember.
 */
typedef struct nogui_toast_activator {
    const nogui_toast_activator_vtbl *lpVtbl;
    LONG refcount;
} nogui_toast_activator;

/*
 * The one activation registration this process has.
 *
 * COM keeps a single class object, cookie, callback and context for an
 * activation: there is nowhere to put a second one, so this state is
 * process-wide by the platform's own shape and not by choice. A second
 * registration is therefore refused rather than allowed to overwrite these,
 * because overwriting them would leave the first holder claiming a click it
 * can never be handed, which is a user answer that goes nowhere.
 *
 * `g_activations_in_flight` is what makes retiring the callback and its
 * context safe rather than merely tidy. `Activate` takes the callback, the
 * context and the count together under this lock, raises the count, calls the
 * pair with the lock released, and lowers the count when it returns. An
 * unregister clears the pair under the same lock and then waits for the count
 * to reach zero, so it returns only once every activation that could still
 * name the retired context has finished. A caller may therefore free its
 * context the moment unregister returns, and a click that was already on its
 * way cannot arrive in it.
 *
 * The invariant that makes that a barrier: taking the pair and raising the count
 * happen in one critical section, and so does clearing the pair. So the count
 * only ever rises for a context the retirement has not taken yet, and a
 * retirement that has cleared the pair can never be followed by a rise: every
 * thread still able to raise it was refused the pair by the very lock the
 * retirement used. Zero is therefore not "no activation yet" but "no activation
 * left that can name this context", and it is what the wait is for.

 * The lock on its own would only say who is listening, not who is finished. The
 * handler releases the lock to convert the argument and to run the callback, so a
 * click that took the pair a moment before the unregister would otherwise arrive
 * at a context the caller has already freed.
 *
 * `g_activator_retiring` keeps a registration that is still draining counted
 * as the process's one registration. A `register` that raced the retirement is
 * refused with `NOGUI_TOAST_BUSY` rather than allowed to publish a context and
 * register a class object before the revoke that retires the previous one has
 * run: that revoke would take the new registration down with the old one, and
 * the caller would be told its callback was live while nothing on the shell's
 * side could reach it.
 */
static BOOL g_activator_registered = FALSE;
static BOOL g_activator_retiring = FALSE;
static DWORD g_class_cookie = 0;
static nogui_toast_activation_fn g_activation_callback = NULL;
static void *g_activation_user = NULL;
/* Touched only under `g_lock`, so it needs no atomic operation of its own. */
static LONG g_activations_in_flight = 0;

/* Give the count back, and wake a retirement that is waiting for the last of
 * the activations it has to outlive. */
static void nogui_toast_activation_finished(void) {
    nogui_toast_lock();
    g_activations_in_flight -= 1;
    if (g_activations_in_flight == 0) {
        WakeAllConditionVariable(&g_drained);
    }
    nogui_toast_unlock();
}

/*
 * Wait until no activation is still holding a callback context.
 *
 * This is the barrier half of an unregister, and it waits on the condition
 * variable rather than on the counter, so a caller retires a registration
 * without spinning a core. The loop is because a wake-up is not a promise:
 * `SleepConditionVariableCS` returns on a signal and also on a timeout, and
 * only the count says the barrier is reached.
 */
static void nogui_toast_await_drained(void) {
    nogui_toast_lock();
    while (g_activations_in_flight != 0) {
        SleepConditionVariableCS(&g_drained, &g_lock, INFINITE);
    }
    nogui_toast_unlock();
}

static HRESULT STDMETHODCALLTYPE nogui_toast_activator_QueryInterface(
    void *self, REFIID iid, void **out) {
    if (out == NULL) {
        return E_POINTER;
    }
    *out = NULL;
    if (self == NULL) {
        return E_POINTER;
    }
    if (IsEqualIID(iid, &IID_IUnknown) ||
        IsEqualIID(iid, &IID_INotificationActivationCallback)) {
        *out = self;
        ((nogui_toast_activator *)self)->lpVtbl->AddRef(self);
        return S_OK;
    }
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE nogui_toast_activator_AddRef(void *self) {
    if (self == NULL) {
        return 0;
    }
    return (ULONG)InterlockedIncrement(
        &((nogui_toast_activator *)self)->refcount);
}

static ULONG STDMETHODCALLTYPE nogui_toast_activator_Release(void *self) {
    if (self == NULL) {
        return 0;
    }
    nogui_toast_activator *owned = (nogui_toast_activator *)self;
    /* The count cannot reach zero: the class object is in static storage and its
     * permanent reference is never handed back, so this file has nothing to
     * release here. The decrement stays because COM's own reference has to be
     * counted, and because the free an ordinary `Release` would do is the one
     * thing this object must never do -- a shell thread may still hold an
     * interface reference to it. */
    return (ULONG)InterlockedDecrement(&owned->refcount);
}

/*
 * The shell's activation call.
 *
 * The SDK declares this as `HRESULT Activate(LPCWSTR appUserModelId, LPCWSTR
 * invokedArgs, const NOTIFICATION_USER_INPUT_DATA *data, ULONG count)`: the
 * arguments arrive as wide strings, not as WinRT handles. The one parameter the
 * host has no channel for is the input array, which is only populated when the
 * toast declared a text input; the XML this library is given never does, so the
 * count is zero by construction and the array is never read.
 *
 * The handler is called on a COM thread, not the host's main thread, and it must
 * return promptly: a failure HRESULT tells the shell the activation failed and
 * lets the user try again. So the argument is copied into a caller-owned buffer,
 * handed over, and freed, and nothing else happens here.
 *
 * The callback is taken together with its context and with the count of the
 * activations holding them, under one lock, and the count is raised before that
 * lock is released. That count is what an unregister waits on, so it covers the
 * whole window in which this call can still name the context: the conversion
 * below and the callback itself both run with the lock released, because a COM
 * thread must not hold this file's lock while it runs host code, and because
 * host code may come back to this file and take the lock itself.
 */
static HRESULT STDMETHODCALLTYPE nogui_toast_activator_Activate(
    void *self, LPCWSTR app_user_model_id, LPCWSTR invoked_args,
    const NOTIFICATION_USER_INPUT_DATA *data, ULONG count) {
    (void)self;
    (void)app_user_model_id;
    (void)data;
    (void)count;

    /*
     * The callback, the context and the count are read together, so a context
     * that an unregister retires is either never taken here or is still counted
     * while it is in use.
     */
    nogui_toast_activation_fn callback = NULL;
    void *user = NULL;
    nogui_toast_lock();
    callback = g_activation_callback;
    user = g_activation_user;
    if (callback != NULL) {
        g_activations_in_flight += 1;
    }
    nogui_toast_unlock();
    if (callback == NULL) {
        /*
         * Nobody is listening. Reported as a refusal rather than a crash: the shell
         * asked a process that is tearing down, and a COM method that fails is how
         * the shell learns that.
         */
        return E_ABORT;
    }

    /* An empty argument is the body activation, which the host's default action is
     * told apart from by whether an argument came back. */
    char *argument = NULL;
    if (invoked_args != NULL && invoked_args[0] != L'\0') {
        const int needed =
            WideCharToMultiByte(CP_UTF8, 0, invoked_args, -1, NULL, 0, NULL, NULL);
        if (needed > 1) {
            argument = (char *)malloc((size_t)needed);
            if (argument != NULL) {
                const int written = WideCharToMultiByte(
                    CP_UTF8, 0, invoked_args, -1, argument, needed, NULL, NULL);
                if (written <= 0) {
                    free(argument);
                    argument = NULL;
                }
            }
        }
    }

    nogui_toast_activation event;
    event.argument = argument;
    event.is_body = (argument == NULL) ? 1 : 0;
    callback(user, &event);
    free(argument);
    /* Handed back only after the callback has returned, which is what lets an
     * unregister that is waiting on this count return. */
    nogui_toast_activation_finished();
    return S_OK;
}

static const nogui_toast_activator_vtbl g_activator_vtbl = {
    nogui_toast_activator_QueryInterface,
    nogui_toast_activator_AddRef,
    nogui_toast_activator_Release,
    nogui_toast_activator_Activate,
};

/*
 * The process's class object, in static storage.
 *
 * The count starts at one and that one is never handed back: it is the
 * permanent reference that makes the object outlive every registration, and
 * COM's own reference, taken by `CoRegisterClassObject` and dropped by
 * `CoRevokeClassObject`, is counted on top of it. Nothing here allocates, so
 * there is no failure path for a registration to take and no object for a
 * second registration to replace.
 */
static nogui_toast_activator g_class_object = {
    &g_activator_vtbl,
    1,
};

/* True when the class points at an executable, which is how COM launches it. */
static BOOL nogui_toast_class_is_registered(const CLSID *clsid) {
    HKEY classes = NULL;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kClassesRoot, 0, KEY_READ, &classes) !=
        ERROR_SUCCESS) {
        return FALSE;
    }
    wchar_t key[64];
    const int written = swprintf(
        key, sizeof(key) / sizeof(key[0]),
        L"{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        (unsigned long)clsid->Data1, (unsigned)clsid->Data2,
        (unsigned)clsid->Data3, (unsigned)clsid->Data4[0],
        (unsigned)clsid->Data4[1], (unsigned)clsid->Data4[2],
        (unsigned)clsid->Data4[3], (unsigned)clsid->Data4[4],
        (unsigned)clsid->Data4[5], (unsigned)clsid->Data4[6],
        (unsigned)clsid->Data4[7]);
    BOOL found = FALSE;
    HKEY class_key = NULL;
    if (written > 0 && (size_t)written < sizeof(key) / sizeof(key[0]) &&
        RegOpenKeyExW(classes, key, 0, KEY_READ, &class_key) == ERROR_SUCCESS) {
        wchar_t value[1024];
        DWORD size = sizeof(value);
        DWORD type = 0;
        found = RegQueryValueExW(class_key, L"LocalServer32", NULL, &type,
                                 (LPBYTE)value, &size) == ERROR_SUCCESS &&
                 type == REG_SZ;
        RegCloseKey(class_key);
    }
    RegCloseKey(classes);
    return found;
}

nogui_toast_status nogui_toast_activator_register(
    const wchar_t *app_id, const wchar_t *cls_id,
    nogui_toast_activation_fn callback, void *user) {
    if (app_id == NULL || app_id[0] == L'\0' || cls_id == NULL ||
        cls_id[0] == L'\0' || callback == NULL) {
        return NOGUI_TOAST_INVALID;
    }
    CLSID clsid;
    const HRESULT parsed = CLSIDFromString(cls_id, &clsid);
    if (FAILED(parsed)) {
        /* A CLSID the SDK cannot parse is a caller mistake, not a platform
         * refusal. */
        return NOGUI_TOAST_INVALID;
    }
    /*
     * The class must already point at an executable. Without that, COM cannot
     * launch the process and the shell's activation lands on nothing, so the
     * registration is refused rather than performed and reported as working.
     */
    if (!nogui_toast_class_is_registered(&clsid)) {
        return NOGUI_TOAST_UNAVAILABLE;
    }

    /*
     * One registration at a time, decided and performed under one lock so two
     * threads cannot both find it free. A registration that is still retiring
     * counts as taken: the revocation that ends it has not run yet, so a class
     * object registered now would be taken down by that revocation, and the
     * caller would be told its callback was live while nothing on the shell's
     * side could reach it. The holder is left completely alone when this call is
     * refused: same cookie, same callback, same context, so the provider that
     * owns them keeps receiving activations.
     */
    nogui_toast_lock();
    if (g_activator_registered || g_activator_retiring) {
        nogui_toast_unlock();
        return NOGUI_TOAST_BUSY;
    }

    /*
     * The class factory hands the shell this instance, and it stays registered
     * for as long as this app can still be activated for a toast it showed,
     * which is until the revocation on the retire side. It is registered as a
     * local server because that is how the shell reaches an executable, and as
     * multiple-use because more than one activation may arrive.
     *
     * The callback and its context are published last, under this same lock, so
     * an activation can never find them ahead of the cookie that delivers one.
     *
     * The SDK call runs with the lock held, and that cannot deadlock the drain:
     * COM does not call into the class object from inside
     * `CoRegisterClassObject`, and were it to, the re-entering thread would find
     * `g_activation_callback` still null and answer `E_ABORT` without naming a
     * context. A COM thread that did call in and was made to wait would wait on
     * this lock, which is released as soon as the SDK call returns, and this
     * thread waits on nothing else. The revocation on the retire side is the
     * mirror image: it runs with no lock held at all, and the callback it
     * retires was already cleared under the lock before the call.
     */
    DWORD cookie = 0;
    const HRESULT hr =
        CoRegisterClassObject(&clsid, (LPUNKNOWN)&g_class_object,
                              CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie);
    if (FAILED(hr)) {
        /* Nothing to undo. The class object is this file's for the life of the
         * process and no state was published, so a failed registration leaves
         * the process exactly as it found it. */
        nogui_toast_unlock();
        return nogui_toast_from_hresult(hr);
    }

    g_class_cookie = cookie;
    g_activation_callback = callback;
    g_activation_user = user;
    g_activator_registered = TRUE;
    nogui_toast_unlock();
    return NOGUI_TOAST_OK;
}

void nogui_toast_activator_unregister(void) {
    DWORD cookie = 0;
    BOOL retiring = FALSE;

    nogui_toast_lock();
    if (g_activator_registered) {
        /*
         * The callback, its context and the cookie are given up together, under
         * one lock, so an activation can never find a revoked class object behind
         * a live callback or a live class object behind no callback at all.
         */
        g_activator_registered = FALSE;
        /* Counted as the process's one registration until the drain below
         * finishes, so a register that races this call is refused rather than
         * raced. */
        g_activator_retiring = TRUE;
        retiring = TRUE;
        cookie = g_class_cookie;
        g_class_cookie = 0;
        g_activation_callback = NULL;
        g_activation_user = NULL;
    }
    nogui_toast_unlock();

    /*
     * The revoke is an SDK call and runs with no lock held. It hands back COM's
     * own reference to the class object, and holding this file's lock across an
     * SDK call would mean a COM thread inside `Activate` could be left waiting
     * for a lock this call is holding. The class object stays allocated, so the
     * reference COM drops here is not the one that keeps it valid.
     */
    if (retiring && cookie != 0) {
        CoRevokeClassObject(cookie);
    }

    /*
     * The barrier. An activation that took the callback before the clear above is
     * still counted, and it is holding the very context the caller is about to
     * free, so this call returns only once the last of them has run the callback
     * and returned. An activation that arrives after the clear takes no context
     * at all and is refused before it can name one.
     *
     * A call that finds nothing registered waits as well: it is the same promise
     * the caller is being given, and another thread may be retiring a
     * registration whose callbacks are still running.
     */
    nogui_toast_await_drained();

    if (retiring) {
        /* The registration is now fully retired, so the next registration may
         * have the cookie and the class factory. */
        nogui_toast_lock();
        g_activator_retiring = FALSE;
        nogui_toast_unlock();
    }
}
