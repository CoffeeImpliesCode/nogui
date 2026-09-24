/*
 * Narrow C ABI over the Windows toast notification platform.
 *
 * The real mechanism is WinRT: `Windows.UI.Notifications.ToastNotificationManager`
 * hands out an `IToastNotifier` for an AppUserModelID, and `IToastNotifier::Show`
 * puts a toast on screen. Both are WinRT interfaces whose declarations live in the
 * Windows SDK, so the SDK call stays in C behind this header and only a status
 * code crosses back. There is no projection on this side, which is why every
 * object this file creates is an ABI interface the SDK already declares.
 *
 * What the host gets to choose is the toast XML, the tag and the group. That is
 * enough for the whole shared contract:
 *
 *   * Identity and replacement are the tag. `put_Tag` with a tag the host already
 *     used replaces the previous toast in place, which is what
 *     `NotificationOptions.replaces_id` means on Windows.
 *   * Dismissal is `IToastNotifier::Hide` for a banner this library still holds a
 *     reference to, plus `IToastNotificationHistory::RemoveGroupedTagWithId` for
 *     Action Center. Windows has no API that retracts a toast it has already
 *     handed to someone else, and a toast this library no longer holds cannot be
 *     retracted at all; the header for `nogui_toast_remove` says which of the two
 *     a caller is getting.
 *   * Actions are `<action>` elements in the XML the host builds, and the
 *     argument the shell hands back on activation is the host's own action key.
 *
 * Packaging is a real prerequisite and it is checked rather than assumed. A
 * desktop toast needs a Start menu shortcut whose `System.AppUserModel.ID` is the
 * claimed AppUserModelID; without one the platform fails *silently*, the toast
 * simply never appears, so no adapter can discover it after the fact and report
 * an honest success. What this library can do is refuse to claim more than it can
 * deliver: `nogui_toast_probe` asks the platform whether notifications are
 * enabled for the identity, and `nogui_toast_activator_register` verifies the
 * COM registration the shell needs to deliver an action.
 *
 * Every failure is a status code. There is no C++ frame and no exception, so
 * nothing can unwind into the Zig caller.
 */
#ifndef NOGUI_TOAST_H
#define NOGUI_TOAST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors `ToastStatus` in src/v7_host/windows/notifications.zig. */
typedef enum nogui_toast_status {
    NOGUI_TOAST_OK = 0,
    /* The platform is not reachable for this identity: WinRT is absent, or the
     * platform answered that it will not attribute a toast to it. Nothing was
     * shown. */
    NOGUI_TOAST_UNAVAILABLE = 1,
    /* The shell refused the request. Distinct from unavailable: the platform
     * answered, and its answer was no. */
    NOGUI_TOAST_DENIED = 2,
    /* The caller supplied something the platform cannot use: an empty identity,
     * an empty or over-long tag, or XML the document parser rejected. */
    NOGUI_TOAST_INVALID = 3,
    /* The call failed for a reason the caller may retry. */
    NOGUI_TOAST_FAILED = 4,
    /* Another registration in this process holds the one COM activation
     * registration a process has, or is still retiring one: a registration that
     * is draining the callbacks it already started has not yet given up its
     * cookie, so it still holds the registration. Nothing of that registration
     * is changed: the holder keeps its class object, its cookie and its
     * callback, and keeps receiving activations. */
    NOGUI_TOAST_BUSY = 5
} nogui_toast_status;

/*
 * Why the platform will not show toasts for an identity, as reported by
 * `IToastNotifier::get_Setting`. The platform documents the precedence as
 * disabled-by-manifest first, then group policy, then user, then application, and
 * this enumeration follows it so a host can tell a user from a policy from a
 * manifest.
 */
typedef enum nogui_toast_blocker {
    NOGUI_TOAST_BLOCKER_NONE = 0,
    NOGUI_TOAST_BLOCKER_DISABLED_BY_MANIFEST = 1,
    NOGUI_TOAST_BLOCKER_DISABLED_BY_GROUP_POLICY = 2,
    NOGUI_TOAST_BLOCKER_DISABLED_FOR_USER = 3,
    NOGUI_TOAST_BLOCKER_DISABLED_FOR_APPLICATION = 4
} nogui_toast_blocker;

/* What `nogui_toast_probe` found. */
typedef struct nogui_toast_probe_result {
    /* The notifier's own setting, as a `nogui_toast_blocker`. */
    nogui_toast_blocker blocker;
    /* True when the identity can show toasts. */
    int can_show;
} nogui_toast_probe_result;

/* One action the user chose, as the activation callback delivers it. Both
 * fields are NUL-terminated UTF-8 and are owned by the shim; the host copies what
 * it keeps. */
typedef struct nogui_toast_activation {
    /* The activation argument the host put in the toast, i.e. its action key, or
     * empty when the user activated the body. */
    const char *argument;
    /* True when the user activated the body rather than an action button. */
    int is_body;
} nogui_toast_activation;

/*
 * The activation handler.
 *
 * It runs on a COM thread the shell chooses, with no lock of this library's
 * held, and it must return promptly: it is inside the shell's call, and a
 * failure HRESULT is how the shell learns that an activation failed and the user
 * may try again.
 *
 * It must not call `nogui_toast_activator_unregister`. That call returns only
 * after every activation still holding a callback has returned, and this
 * activation is one of them, so an unregister from inside this function would be
 * waiting for a call that cannot finish until this one does.
 *
 * Every other call in this header is safe from here: none of them waits for an
 * activation, and none of them is made with a lock held, so this library cannot
 * be entered by a path that closes on itself.
 *
 * `event` belongs to this library and is valid only until this function
 * returns. `user` is the caller's own pointer and must stay valid for as long as
 * the registration is held, which ends when `nogui_toast_activator_unregister`
 * returns.
 */

typedef void (*nogui_toast_activation_fn)(void *user,
                                          const nogui_toast_activation *event);

/*
 * Initialize WinRT for the calling thread.
 *
 * Returns 1 when this call initialized the runtime and the caller must balance it
 * with `nogui_toast_runtime_uninit`, 0 when the thread already had a usable
 * runtime that this library did not start, and -1 when the thread cannot have one.
 * Both a nested init and one on a thread already initialized count as 1, so the
 * balance is always possible.
 */
int nogui_toast_runtime_init(void);

/* Balance one `nogui_toast_runtime_init` that returned 1. Safe on NULL. */
void nogui_toast_runtime_uninit(void);

/*
 * Ask whether toasts can be shown for `app_id`, and why not when they cannot.
 *
 * This is the platform's own answer, from `IToastNotifier::get_Setting`, not a
 * guess at whether a Start menu shortcut exists. The shortcut itself is a
 * packaging fact this library cannot observe: a desktop toast with no shortcut
 * carrying the identity fails silently on Windows, so a host that needs proof
 * must have its installer create it.
 *
 * `out` may be null when the caller only wants the status.
 */
nogui_toast_status nogui_toast_probe(const wchar_t *app_id,
                                     nogui_toast_probe_result *out);

/*
 * Show a toast.
 *
 * `xml` is the complete `<toast>` document; `tag` and `group` are the identity the
 * shell groups and replaces by, and either may be null when the host wants no tag
 * at all. A tag is what makes a later dismissal possible, so a host that intends
 * to be able to dismiss submits a tag. An empty tag is refused because the
 * platform rejects one, and a tag longer than the platform's limit is refused
 * rather than truncated, because a truncated tag is a different identity.
 *
 * Every platform object this call needs is created and released inside it, on the
 * calling thread, so the call is correct from any thread and leaves nothing
 * behind for the next one.
 */
nogui_toast_status nogui_toast_show(const wchar_t *app_id, const wchar_t *xml,
                                    const wchar_t *tag, const wchar_t *group);

/*
 * Dismiss the toast carrying `tag` and `group`.
 *
 * A banner this library still holds a reference to is retracted with
 * `IToastNotifier::Hide`, and the toast is removed from Action Center with
 * `RemoveGroupedTagWithId`. A banner this library no longer holds can only be
 * removed from Action Center, because Windows offers no API to retract a toast
 * whose object the app has released; that is a limit of the platform, reported
 * rather than hidden.
 */
nogui_toast_status nogui_toast_remove(const wchar_t *app_id, const wchar_t *tag,
                                      const wchar_t *group);

/*
 * Register this process as the COM activation handler for its own toasts, and hand
 * the host the callback that receives an activation.
 *
 * `cls_id` is the CLSID in registry form. The class must already be registered
 * under `HKCU\Software\Classes\CLSID` with a `LocalServer32` value, because that
 * is what lets COM launch this executable; this call verifies it and reports
 * `NOGUI_TOAST_UNAVAILABLE` when it is absent rather than registering something
 * the shell will never find. Binding the AppUserModelID to the CLSID is the
 * installer's job, through the shortcut's `System.AppUserModel.ToastActivatorCLSID`
 * property, and is named in the module comment because it is the other half of
 * the same prerequisite.
 *
 * There is one activation registration per process, not one per call. COM keeps
 * a single class object, cookie, callback and context for an activation, so a
 * second registration with a different class or a different context cannot have
 * one of its own. This call reports `NOGUI_TOAST_BUSY` in that case and changes
 * nothing: the holder keeps its callback, its cookie and its context, and keeps
 * receiving activations. The host counts the registration as a lease for this
 * reason, so a provider that is refused shows toasts with no action delivery
 * instead of taking an answer away from the provider that can deliver one.
 *
 * A registration that is still retiring is still this process's one
 * registration: the revocation that ends it has not run yet, so this call
 * reports `NOGUI_TOAST_BUSY` while that drain finishes rather than registering a
 * class object the revocation would take down with the old one.
 *
 * The callback runs on a COM thread the shell chooses, which is not the host's
 * main thread. It may arrive at any moment, including while the caller is
 * unregistering, and its own contract is stated with the callback type above.
 *
 * `user` is owned by the caller and must stay valid until
 * `nogui_toast_activator_unregister` returns for this registration. That call is
 * the barrier: after it returns no activation can call this callback or name
 * `user` again, so it is where the caller gets the pointer back and where the
 * caller may free it. Nothing before that point releases it, and a second
 * registration is refused rather than allowed to take a pointer the first one
 * still owns.
 */
nogui_toast_status nogui_toast_activator_register(
    const wchar_t *app_id, const wchar_t *cls_id,
    nogui_toast_activation_fn callback, void *user);

/*
 * Give the in-process activation handler back: the class object is revoked and
 * the callback is dropped together.
 *
 * This call is the barrier, not a flag. It drops the callback and its context,
 * revokes the class object, and then waits for every activation that had already
 * taken that callback to return. It can therefore block, for as long as one
 * activation's callback takes, and it waits for nothing else. An activation that
 * arrives while it waits finds no callback and is refused to the shell rather
 * than delivered.
 *
 * When it returns, no activation can name the context the caller registered, so
 * the caller owns that pointer again and may free it, and the process's one
 * registration is free for the next `nogui_toast_activator_register`.
 *
 * A call with no registration set is a no-op, so the caller that registered
 * once may release once without checking whether something else already did. It
 * still waits out a retirement another thread is running, because that is the
 * same promise.
 */
void nogui_toast_activator_unregister(void);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_TOAST_H */
