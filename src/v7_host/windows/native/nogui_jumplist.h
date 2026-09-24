/*
 * Narrow C ABI over the Windows shell jump list.
 *
 * A jump list is a list of COM objects. `ICustomDestinationList` is declared in
 * `shobjidl_core.h`, its coclass is instantiated through `CoCreateInstance`,
 * and a task is an `IShellLink` with a `System.Title` property. None of that is
 * expressible as a Zig `extern`, and hand-writing a COM vtable would be a guess
 * at an ABI the SDK already states, so the COM lives here and the Zig side keeps
 * the model, the identity gate and the routing.
 *
 * The sequence is the one the SDK documents for this interface:
 *
 *   1. `CoCreateInstance(CLSID_DestinationList)` for `ICustomDestinationList`.
 *   2. `SetAppID` names the app whose taskbar button holds the list. The SDK
 *      requires it, and only it, before `BeginList` whenever the application
 *      declares its own AppUserModelID, and reports `E_UNEXPECTED` if it is
 *      called after `BeginList`.
 *   3. `BeginList` opens the list-building transaction and hands back the items
 *      the user removed.
 *   4. `SHAddToRecentDocs` records each document, and `AppendKnownCategory`
 *      with `KDC_RECENT` shows the shell's own Recent category.
 *   5. `AddUserTasks` with an `IObjectArray` of `IShellLink` objects fills the
 *      Tasks category.
 *   6. `CommitList` publishes. Until it returns, the taskbar keeps showing the
 *      previous list.
 *
 * The user-removal array from `BeginList` is released and not consulted. That is
 * not an oversight: `AppendKnownCategory` shows the shell's own Recent list,
 * which already honours a removal, and the SDK states that a user can neither
 * pin nor remove a task.
 */
#ifndef NOGUI_JUMPLIST_H
#define NOGUI_JUMPLIST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors `Status` in src/v7_host/windows/jump_list.zig. The values are a wire
 * contract between the two, so they are spelled out rather than shared through a
 * generated header. */
typedef enum nogui_jump_status {
    NOGUI_JUMP_OK = 0,
    /* The process holds no explicit AppUserModelID, so there is no taskbar
     * button for a list to belong to. Named apart from SHELL_REFUSED because
     * nothing was asked of the shell. */
    NOGUI_JUMP_IDENTITY_UNSET = 1,
    /* COM could not be initialized or the coclass could not be created. */
    NOGUI_JUMP_COM_UNAVAILABLE = 2,
    /* The shell refused a list operation. */
    NOGUI_JUMP_SHELL_REFUSED = 3,
    /* An entry names nothing: an empty title, an empty action name, or an empty
     * document path. Refused rather than published blank. */
    NOGUI_JUMP_INVALID_ENTRY = 4,
    /* The identity the caller asked for is not the identity the process holds,
     * so the list would belong to another app's taskbar button. */
    NOGUI_JUMP_IDENTITY_MISMATCH = 5,
    /* A buffer this call needed could not be allocated. */
    NOGUI_JUMP_OUT_OF_MEMORY = 6
} nogui_jump_status;

/* One task to publish. Every string is borrowed for the duration of the call
 * and must be NUL-terminated UTF-16. `description` may be NULL. */
typedef struct nogui_jump_task {
    const wchar_t *title;
    const wchar_t *action_name;
    const wchar_t *description;
} nogui_jump_task;

/* One recent document to record. `display_name` is the name the app would show;
 * the shell takes the display name from the file itself, so it is accepted for
 * the caller's own bookkeeping and is not published here. */
typedef struct nogui_jump_document {
    const wchar_t *path;
    const wchar_t *display_name;
} nogui_jump_document;

/*
 * Build and publish the jump list of one AppUserModelID.
 *
 * `app_id` is the identity the process declared. The call refuses before it
 * initializes COM when the process holds no explicit identity, and again when
 * the identity it holds is not this one, so a list is never published against a
 * taskbar button that belongs to a different app. The shell refuses a list whose
 * `SetAppID` it will not store.
 *
 * A task is published as a shortcut to this process carrying the task's action
 * name as its command-line argument, so selecting it starts the app with the
 * action name the caller published. The host decodes that command line into the
 * selection it routes.
 *
 * Every failure, including allocation failure, is a status. There is no C++ frame
 * and no exception, so nothing can unwind into the Zig caller.
 */
nogui_jump_status nogui_jump_publish(const wchar_t *app_id,
                                     const nogui_jump_task *tasks,
                                     unsigned int task_count,
                                     const nogui_jump_document *documents,
                                     unsigned int document_count);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_JUMPLIST_H */
