/*
 * The Windows jump list, behind a narrow status-and-views ABI.
 *
 * Everything here is COM the SDK already declares: `ICustomDestinationList`
 * from `shobjidl_core.h`, `IShellLinkW` with its `IPropertyStore`, and
 * `IObjectCollection`/`IObjectArray` for the task batch. None of those
 * interfaces is spelled out locally, so a wrong method order is a link error
 * and a wrong IID is a runtime `E_NOINTERFACE` rather than a call against the
 * wrong object.
 *
 * The identity gate runs before COM exists. The list belongs to the taskbar
 * button of the app whose identity it names, so a process that never called
 * `SetCurrentProcessExplicitAppUserModelID` has no button to hold it, and a
 * process whose identity is not the one being published would file its list
 * under somebody else's button. Both are refused by name.
 *
 * The transaction is `SetAppID`, `BeginList`, the categories, `CommitList`, and
 * every object leaves through one macro that forgets what it released.
 * `CommitList` publishes; until it returns the shell keeps showing the
 * previous list.
 *
 * ONE effect sits outside that transaction, because the shell offers no way to
 * take it back: `SHAddToRecentDocs` writes the user's per-user recent store,
 * and that store is what the Recent category is built from. It is therefore
 * the LAST thing this file does before `CommitList` -- every step that can
 * fail has already run -- so a refused publish leaves the store untouched for
 * every reason a caller can reach except a `CommitList` the shell itself
 * refuses, which nothing here can predict.
 */
#include "nogui_jumplist.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <propsys.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <objectarray.h>
#include <stdlib.h>
#include <wchar.h>

/*
 * Release one owned COM pointer, exactly once, and forget it.
 *
 * Every COM pointer this file owns is acquired into a local that starts NULL,
 * and every path out of the function that holds it passes the pointer through
 * here. The macro NULLs the pointer as part of the release, so a second pass
 * over the same variable is a no-op instead of a second `Release`: an
 * exactly-once release is a property of the code rather than of the care
 * taken by whoever adds the next exit.
 */
#define NOGUI_JUMP_RELEASE(pointer)              \
    do {                                         \
        if ((pointer) != NULL) {                 \
            (pointer)->lpVtbl->Release(pointer); \
            (pointer) = NULL;                    \
        }                                        \
    } while (0)

/*
 * The documented identifiers.
 *
 * `CLSID_DestinationList` and `CLSID_EnumerableObjectCollection` are the
 * coclasses `ICustomDestinationList` and `IObjectCollection` are implemented
 * by. `IID_ICustomDestinationList`, `IID_IObjectCollection` and
 * `IID_IObjectArray` are the interface identifiers the MIDL_INTERFACE lines
 * carry. `CLSID_ShellLink`, `IID_IShellLinkW` and `IID_IPropertyStore` are the
 * ones the task link needs. `PKEY_Title` is `System.Title`, which the SDK
 * requires on every jump list task and which holds the display name. Every value
 * here is the one the IDL headers state, spelled as a constant so no import
 * library symbol for a GUID is needed.
 */
static const GUID NOGUI_CLSID_DestinationList = {
    0x77f10cf0, 0x3db5, 0x4966, {0xb5, 0x20, 0xb7, 0xc5, 0x4f, 0xd3, 0x5e, 0xd6}};
static const GUID NOGUI_IID_ICustomDestinationList = {
    0x6332debf, 0x87b5, 0x4670, {0x90, 0xc0, 0x5e, 0x57, 0xb4, 0x08, 0xa4, 0x9e}};
static const GUID NOGUI_CLSID_EnumerableObjectCollection = {
    0x2d3468c1, 0x36a7, 0x43b6, {0xac, 0x24, 0xd3, 0xf0, 0x2f, 0xd9, 0x60, 0x7a}};
static const GUID NOGUI_IID_IObjectCollection = {
    0x5632b1a4, 0xe38a, 0x400a, {0x92, 0x8a, 0xd4, 0xcd, 0x63, 0x23, 0x02, 0x95}};
static const GUID NOGUI_IID_IObjectArray = {
    0x92ca9dcd, 0x5622, 0x4bba, {0xa8, 0x05, 0x5e, 0x9f, 0x54, 0x1b, 0xd8, 0xc9}};
static const GUID NOGUI_CLSID_ShellLink = {
    0x00021401, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID NOGUI_IID_IShellLinkW = {
    0x000214f9, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID NOGUI_IID_IPropertyStore = {
    0x886d8eeb, 0x8cf2, 0x4446, {0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99}};
static const PROPERTYKEY NOGUI_PKEY_Title = {
    {0xf29f85e0, 0x4ff9, 0x1068, {0xab, 0x91, 0x08, 0x00, 0x2b, 0x27, 0xb3, 0xd9}},
    2};

/*
 * One task as the shell wants it: a shortcut to this process, carrying the
 * action name as its command-line argument, named through `System.Title`.
 *
 * The SDK states that a task with no argument list is not supported, and that
 * the display name has to be the item's `System.Title` property rather than
 * anything on the link itself. Both are therefore set, and the icon comes from
 * the executable so a task never shows the blank default.
 */
static HRESULT nogui_jump_make_task_link(const wchar_t *exe_path,
                                         const nogui_jump_task *task,
                                         IShellLinkW **out_link) {
    IShellLinkW *link = NULL;
    IPropertyStore *store = NULL;
    HRESULT hr;

    *out_link = NULL;
    hr = CoCreateInstance(&NOGUI_CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                          &NOGUI_IID_IShellLinkW, (void **)&link);
    if (FAILED(hr)) {
        return hr;
    }

    hr = link->lpVtbl->SetPath(link, exe_path);
    if (SUCCEEDED(hr)) {
        hr = link->lpVtbl->SetArguments(link, task->action_name);
    }
    if (SUCCEEDED(hr)) {
        hr = link->lpVtbl->SetIconLocation(link, exe_path, 0);
    }
    if (SUCCEEDED(hr) && task->description != NULL) {
        hr = link->lpVtbl->SetDescription(link, task->description);
    }
    if (FAILED(hr)) {
        NOGUI_JUMP_RELEASE(link);
        return hr;
    }

    hr = link->lpVtbl->QueryInterface(link, &NOGUI_IID_IPropertyStore,
                                      (void **)&store);
    if (FAILED(hr)) {
        NOGUI_JUMP_RELEASE(link);
        return hr;
    }

    /*
     * The variant borrows the caller's string, so it holds a pointer into the
     * caller's frame and must never be cleared: `PropVariantClear` would free
     * that pointer with `CoTaskMemFree`. `SetValue` copies the string, and the
     * rest of the variant is zero, which is what `PropVariantInit` produces.
     */
    {
        PROPVARIANT title;
        PropVariantInit(&title);
        title.vt = VT_LPWSTR;
        title.pwszVal = (LPWSTR)task->title;
        hr = store->lpVtbl->SetValue(store, &NOGUI_PKEY_Title, &title);
    }
    if (SUCCEEDED(hr)) {
        hr = store->lpVtbl->Commit(store);
    }
    NOGUI_JUMP_RELEASE(store);
    if (FAILED(hr)) {
        NOGUI_JUMP_RELEASE(link);
        return hr;
    }

    *out_link = link;
    return S_OK;
}

/*
 * Show the shell's own Recent category in the list.
 *
 * The shell owns that category, so it also owns a user's decision to remove an
 * item from it; the app's own recent-document model stays the routing table on
 * the Zig side and is not duplicated into a second list. An empty document
 * list appends no category: the SDK shows every appended category even when it
 * has no entries, and an empty Recent heading is noise the user cannot act on.
 * The caller therefore calls this only for a non-empty list.
 */
static HRESULT nogui_jump_append_recent_category(ICustomDestinationList *list) {
    return list->lpVtbl->AppendKnownCategory(list, KDC_RECENT);
}

/*
 * Record the documents the app recently opened.
 *
 * This is the one write in this file the shell gives no way to take back: it
 * lands in the user's per-user recent store, which is where the Recent
 * category reads from, and it survives a `CommitList` the shell later
 * refuses. So it is written last, after every step that can fail, and before
 * the commit that makes the category show it.
 *
 * `SHAddToRecentDocs` returns nothing, so this records what it was asked to
 * record and the shell's own category is what reflects it afterwards. It takes
 * no COM pointer and therefore has nothing to release.
 */
static void nogui_jump_record_documents(const nogui_jump_document *documents,
                                        unsigned int document_count) {
    unsigned int index;

    for (index = 0; index < document_count; index += 1) {
        SHAddToRecentDocs(SHARD_PATHW, (LPCVOID)documents[index].path);
    }
}

/*
 * The path of this process, owned by the caller.
 *
 * `MAX_PATH` is not the limit on a Windows path, and a truncated path would
 * point every task at nothing, so the buffer grows until the name fits. A path
 * that still does not fit is a failure with its own status rather than a link
 * that silently names the wrong file.
 */
static wchar_t *nogui_jump_module_path(nogui_jump_status *out_status) {
    DWORD capacity = MAX_PATH;
    for (;;) {
        wchar_t *buffer = (wchar_t *)malloc((size_t)capacity * sizeof(wchar_t));
        if (buffer == NULL) {
            *out_status = NOGUI_JUMP_OUT_OF_MEMORY;
            return NULL;
        }
        const DWORD written = GetModuleFileNameW(NULL, buffer, capacity);
        if (written == 0) {
            free(buffer);
            *out_status = NOGUI_JUMP_SHELL_REFUSED;
            return NULL;
        }
        if (written < capacity) {
            *out_status = NOGUI_JUMP_OK;
            return buffer;
        }
        /* The documented answer when the name does not fit is the size the
         * buffer would need, truncated to `DWORD`, so doubling is enough and a
         * path that cannot fit at all is caught by the cap below. */
        free(buffer);
        if (capacity >= 0x10000) {
            *out_status = NOGUI_JUMP_SHELL_REFUSED;
            return NULL;
        }
        capacity *= 2;
    }
}

/*
 * The identity gate. The list is filed under the identity `SetAppID` names, so
 * it has to be the identity this process holds; anything else would publish one
 * app's tasks on another app's taskbar button.
 *
 * The readback is a `CoTaskMemAlloc` buffer and `CoTaskMemFree` is the only
 * release the SDK documents for it, so every path out of here frees it.
 */
static nogui_jump_status nogui_jump_check_identity(const wchar_t *app_id) {
    PWSTR held = NULL;
    HRESULT hr = GetCurrentProcessExplicitAppUserModelID(&held);
    if (FAILED(hr)) {
        return NOGUI_JUMP_IDENTITY_UNSET;
    }
    if (held == NULL || held[0] == L'\0') {
        if (held != NULL) {
            CoTaskMemFree((PVOID)held);
        }
        return NOGUI_JUMP_IDENTITY_UNSET;
    }
    /* AppUserModelIDs are compared without regard to case by the shell. */
    const nogui_jump_status mismatch = _wcsicmp(held, app_id) == 0
                                           ? NOGUI_JUMP_OK
                                           : NOGUI_JUMP_IDENTITY_MISMATCH;
    CoTaskMemFree((PVOID)held);
    return mismatch;
}

/*
 * Whether one task's action name can be the WHOLE argument of a launched
 * process.
 *
 * A task is published as a shortcut whose argument list IS its action name,
 * and the shell appends that string to the target path as it stands: this is a
 * command-line tail, not a list, and nothing escapes it here. The shell's own
 * splitter then breaks the result into arguments. Whitespace splits one entry
 * into two arguments, a double quote opens a quoted run the action name never
 * ends, and a trailing backslash escapes the quote around everything after it.
 *
 * A name carrying any of those produces a command line this process cannot
 * decode back into the action name, so the entry would sit in the user's
 * taskbar menu and do nothing when chosen. The Zig model refuses such an entry
 * before this call is made; the same refusal is repeated here because this is
 * the boundary that writes the argument list.
 */
static int nogui_jump_action_is_launchable(const wchar_t *action_name) {
    const size_t length = wcslen(action_name);
    size_t index;

    if (length == 0) {
        return 0;
    }
    for (index = 0; index < length; index += 1) {
        const wchar_t character = action_name[index];
        if (character == L'\"' || character == L' ' || character == L'\t' ||
            character == L'\n' || character == L'\r' || character == L'\v' ||
            character == L'\f') {
            return 0;
        }
    }
    return action_name[length - 1] != L'\\';
}

nogui_jump_status nogui_jump_publish(const wchar_t *app_id,
                                     const nogui_jump_task *tasks,
                                     unsigned int task_count,
                                     const nogui_jump_document *documents,
                                     unsigned int document_count) {
    ICustomDestinationList *list = NULL;
    IObjectCollection *tasks_collection = NULL;
    IObjectArray *tasks_array = NULL;
    IObjectArray *removed = NULL;
    IShellLinkW *link = NULL;
    wchar_t *exe_path = NULL;
    UINT min_slots = 0;
    unsigned int index;
    HRESULT hr;
    BOOL uninitialize = FALSE;
    nogui_jump_status status = NOGUI_JUMP_SHELL_REFUSED;

    if (app_id == NULL || app_id[0] == L'\0') {
        return NOGUI_JUMP_IDENTITY_UNSET;
    }
    status = nogui_jump_check_identity(app_id);
    if (status != NOGUI_JUMP_OK) {
        return status;
    }

    /* A count without an array is a caller error, not an empty list. */
    if (task_count > 0 && tasks == NULL) {
        return NOGUI_JUMP_INVALID_ENTRY;
    }
    if (document_count > 0 && documents == NULL) {
        return NOGUI_JUMP_INVALID_ENTRY;
    }
    /* Every entry is checked before COM exists, so a list that would be
     * published blank, or that would carry a task the launch door can never
     * decode, is refused without touching the shell at all. */
    for (index = 0; index < task_count; index += 1) {
        if (tasks[index].title == NULL || tasks[index].title[0] == L'\0' ||
            tasks[index].action_name == NULL ||
            tasks[index].action_name[0] == L'\0') {
            return NOGUI_JUMP_INVALID_ENTRY;
        }
        if (!nogui_jump_action_is_launchable(tasks[index].action_name)) {
            return NOGUI_JUMP_INVALID_ENTRY;
        }
    }
    for (index = 0; index < document_count; index += 1) {
        if (documents[index].path == NULL || documents[index].path[0] == L'\0') {
            return NOGUI_JUMP_INVALID_ENTRY;
        }
    }

    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (hr == RPC_E_CHANGED_MODE) {
        /* The thread already has COM in another apartment. Use it, and leave it
         * alone: this call did not start it. */
        uninitialize = FALSE;
    } else if (SUCCEEDED(hr)) {
        uninitialize = TRUE;
    } else {
        return NOGUI_JUMP_COM_UNAVAILABLE;
    }

    /* A task is a shortcut to this process, so the process path is the target
     * of every one of them. */
    exe_path = nogui_jump_module_path(&status);
    if (exe_path == NULL) {
        goto done;
    }

    hr = CoCreateInstance(&NOGUI_CLSID_DestinationList, NULL,
                          CLSCTX_INPROC_SERVER, &NOGUI_IID_ICustomDestinationList,
                          (void **)&list);
    if (FAILED(hr)) {
        status = NOGUI_JUMP_COM_UNAVAILABLE;
        goto done;
    }

    /*
     * Names the taskbar button the list belongs to. The SDK requires this call
     * before `BeginList` for an application that declares its own
     * AppUserModelID, and answers `E_UNEXPECTED` if the transaction already
     * started, so the order here is part of the contract rather than a habit.
     */
    hr = list->lpVtbl->SetAppID(list, app_id);
    if (FAILED(hr)) {
        goto done;
    }

    /* The list-building transaction. `removed` holds the items the user took out
     * of the previous list; the Recent category and the Tasks category are both
     * owned by the shell, which already honours that decision, so the array is
     * released without being re-added to. */
    hr = list->lpVtbl->BeginList(list, &min_slots, &NOGUI_IID_IObjectArray,
                                 (void **)&removed);
    if (FAILED(hr)) {
        goto done;
    }

    if (document_count > 0) {
        hr = nogui_jump_append_recent_category(list);
        if (FAILED(hr)) {
            goto done;
        }
    }

    if (task_count > 0) {
        hr = CoCreateInstance(&NOGUI_CLSID_EnumerableObjectCollection, NULL,
                              CLSCTX_INPROC, &NOGUI_IID_IObjectCollection,
                              (void **)&tasks_collection);
        if (FAILED(hr)) {
            status = NOGUI_JUMP_COM_UNAVAILABLE;
            goto done;
        }
        for (index = 0; index < task_count; index += 1) {
            hr = nogui_jump_make_task_link(exe_path, &tasks[index], &link);
            if (FAILED(hr)) {
                goto done;
            }
            hr = tasks_collection->lpVtbl->AddObject(tasks_collection,
                                                     (IUnknown *)link);
            NOGUI_JUMP_RELEASE(link);
            if (FAILED(hr)) {
                goto done;
            }
        }
        hr = tasks_collection->lpVtbl->QueryInterface(
            tasks_collection, &NOGUI_IID_IObjectArray, (void **)&tasks_array);
        if (FAILED(hr)) {
            goto done;
        }
        /* Tasks always appear in the canonical Tasks category, last in the list,
         * and the user can neither pin nor remove them. */
        hr = list->lpVtbl->AddUserTasks(list, tasks_array);
        if (FAILED(hr)) {
            goto done;
        }
    }

    /* The one effect with no rollback, written after every step that can fail
     * and before the commit that makes the category show it. */
    nogui_jump_record_documents(documents, document_count);
    hr = list->lpVtbl->CommitList(list);
    if (FAILED(hr)) {
        goto done;
    }
    status = NOGUI_JUMP_OK;

done:
    NOGUI_JUMP_RELEASE(link);
    NOGUI_JUMP_RELEASE(tasks_array);
    NOGUI_JUMP_RELEASE(tasks_collection);
    NOGUI_JUMP_RELEASE(removed);
    NOGUI_JUMP_RELEASE(list);
    free(exe_path);
    if (uninitialize) {
        CoUninitialize();
    }
    return status;
}
