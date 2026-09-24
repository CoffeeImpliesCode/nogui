/*
 * The Windows credential prompt, behind a narrow status-and-bytes ABI.
 *
 * The entry point is `CredUIPromptForWindowsCredentialsW` from `wincred.h`,
 * which is the supported prompt. It is documented to return `ERROR_SUCCESS`
 * when it succeeds and to report every other outcome through `GetLastError`,
 * so both are read here and neither is assumed:
 *
 *   1. The dialog writes into an opaque packed buffer that this function owns.
 *   2. `CredUnPackAuthenticationBufferW` turns that buffer into a user name and a
 *      password. The SDK's documented limits are tried first, and the one
 *      documented undersize answer is retried once with the sizes the SDK asked
 *      for, so a credential longer than the constant is still read rather than
 *      refused.
 *   3. The account the dialog reported is compared against the account the
 *      caller asked about. A mismatch is refused: the secret belongs to the
 *      account the user typed, and filing it under the requested one would
 *      store it against an account nobody authenticated.
 *   4. The password is converted to owned UTF-8, and the stack buffers, the
 *      packed buffer and every intermediate copy are wiped on every path out,
 *      including every failure.
 *
 * The Save check box is not requested: `CREDUIWIN_CHECKBOX` is not set, so a
 * user is never offered a choice this prompt cannot carry out. The function
 * never writes a credential, so there is nothing here that could honour it.
 *
 * Threading, which is the part that decides whether this is usable at all: the
 * prompt is a modal dialog on the calling thread, and an interactive window
 * station is the documented precondition for showing any UI at all. A service
 * session has such a handle and is simply not visible, and a prompt there would
 * block with nothing on screen, so the station is checked before the dialog.
 */
#include "nogui_credui.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
/* `CredUIPromptForWindowsCredentialsW` and `CredUnPackAuthenticationBufferW`
 * are declared in `wincred.h`; `CoTaskMemFree`, which is the documented release
 * for the packed buffer, is declared here. */
#include <objbase.h>
#include <wincred.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/*
 * `CREDUIWIN_GENERIC` asks the provider for the user name and password as plain
 * text, which is the only form `CredUnPackAuthenticationBufferW` can read back
 * and the only form this store holds. It is documented as incompatible with
 * `CREDUIWIN_SECURE_PROMPT`, which is not set here.
 */
#define NOGUI_CRED_FLAGS CREDUIWIN_GENERIC

/*
 * The unpacked sizes to try first. They are the SDK's own documented maxima
 * plus the terminating null, and an answer that does not fit is retried once at
 * the sizes the SDK asks for.
 */
#define NOGUI_CRED_USER_CHARS ((DWORD)CREDUI_MAX_USERNAME_LENGTH + 1)
#define NOGUI_CRED_DOMAIN_CHARS ((DWORD)CREDUI_MAX_USERNAME_LENGTH + 1)
#define NOGUI_CRED_PASSWORD_CHARS ((DWORD)CREDUI_MAX_PASSWORD_LENGTH + 1)

/*
 * The three unpacked fields, owned. Each is a buffer of the size the SDK asked
 * for with the size kept beside it, so a credential longer than the documented
 * limits is read rather than truncated, and so every buffer can be wiped at its
 * real length on the way out.
 */
typedef struct nogui_cred_fields {
    WCHAR *user;
    DWORD user_chars;
    WCHAR *domain;
    DWORD domain_chars;
    WCHAR *password;
    DWORD password_chars;
} nogui_cred_fields;

/*
 * Wipe and release one field set. The password is in one of these and the
 * account in two, so none of them may be left readable for the next call to
 * overwrite by accident.
 */
static void nogui_cred_fields_release(nogui_cred_fields *fields) {
    if (fields->user != NULL) {
        SecureZeroMemory(fields->user, fields->user_chars * sizeof(WCHAR));
        free(fields->user);
        fields->user = NULL;
        fields->user_chars = 0;
    }
    if (fields->domain != NULL) {
        SecureZeroMemory(fields->domain, fields->domain_chars * sizeof(WCHAR));
        free(fields->domain);
        fields->domain = NULL;
        fields->domain_chars = 0;
    }
    if (fields->password != NULL) {
        SecureZeroMemory(fields->password,
                         fields->password_chars * sizeof(WCHAR));
        free(fields->password);
        fields->password = NULL;
        fields->password_chars = 0;
    }
}

/* Allocate one field set. Every size is in characters, null included. */
static BOOL nogui_cred_fields_alloc(nogui_cred_fields *fields, DWORD user_chars,
                                    DWORD domain_chars, DWORD password_chars) {
    fields->user = (WCHAR *)calloc(user_chars, sizeof(WCHAR));
    fields->domain = (WCHAR *)calloc(domain_chars, sizeof(WCHAR));
    fields->password = (WCHAR *)calloc(password_chars, sizeof(WCHAR));
    fields->user_chars = user_chars;
    fields->domain_chars = domain_chars;
    fields->password_chars = password_chars;
    return fields->user != NULL && fields->domain != NULL &&
           fields->password != NULL;
}

/*
 * An interactive window station is the documented precondition for showing any
 * UI at all. `WSF_VISIBLE` is what says the station is on a visible desktop;
 * a service session's station is not, and a prompt there would block forever
 * with nothing on screen.
 */
static BOOL nogui_cred_can_prompt(void) {
    HWINSTA station = GetProcessWindowStation();
    if (station == NULL) {
        return FALSE;
    }
    USEROBJECTFLAGS flags = 0;
    DWORD needed = 0;
    if (!GetUserObjectInformationW(station, UOI_FLAGS, &flags, sizeof(flags),
                                   &needed)) {
        return FALSE;
    }
    return (flags & WSF_VISIBLE) != 0;
}

/*
 * One naming of the Windows error codes this prompt produces. `ERROR_CANCELLED`
 * is the one the shim exists partly to distinguish: the user closed the dialog,
 * which the host contract calls a dismissed prompt and keeps separate from the
 * app's own cancellation token.
 */
static nogui_cred_status nogui_cred_classify(DWORD code) {
    switch (code) {
    case ERROR_SUCCESS:
        return NOGUI_CRED_OK;
    case ERROR_CANCELLED:
        return NOGUI_CRED_CANCELLED;
    case ERROR_ACCESS_DENIED:
    case ERROR_LOGON_FAILURE:
    case ERROR_BAD_USERNAME:
    case ERROR_INVALID_CREDENTIAL:
        return NOGUI_CRED_DENIED;
    case ERROR_NO_SUCH_LOGON_SESSION:
    case ERROR_PASSWORD_EXPIRED:
    case ERROR_ACCOUNT_DISABLED:
        /* The store's own locked: the credential exists and cannot be used
         * until the session, the password or the account comes back. */
        return NOGUI_CRED_LOCKED;
    case ERROR_INVALID_FLAGS:
    case ERROR_INVALID_NAME:
    case ERROR_INVALID_PARAMETER:
    case ERROR_NOT_SUPPORTED:
    case ERROR_BAD_NETPATH:
    case ERROR_NO_LOGON_SERVERS:
        return NOGUI_CRED_FAILED;
    default:
        return NOGUI_CRED_FAILED;
    }
}

/*
 * One unpack call against a field set. `fields` holds the sizes it was
 * allocated with, and the SDK writes back the sizes it actually needed, which
 * is what makes the one documented retry possible.
 */
static BOOL nogui_cred_unpack_once(LPVOID packed, DWORD packed_size,
                                   nogui_cred_fields *fields) {
    DWORD user_chars = fields->user_chars;
    DWORD domain_chars = fields->domain_chars;
    DWORD password_chars = fields->password_chars;
    const BOOL unpacked =
        CredUnPackAuthenticationBufferW(0, packed, packed_size, fields->user,
                                        &user_chars, fields->domain,
                                        &domain_chars, fields->password,
                                        &password_chars);
    fields->user_chars = user_chars;
    fields->domain_chars = domain_chars;
    fields->password_chars = password_chars;
    return unpacked;
}

/*
 * True when `account` names the credential the dialog produced.
 *
 * CredUI reports the user name and the domain as two fields, and a generic
 * credential may report either the bare account or `DOMAIN\account`. All three
 * spellings are accepted, because they are the same identity, and nothing else
 * is: a name this comparison does not recognise belongs to another account.
 */
static BOOL nogui_cred_matches_account(const WCHAR *user, const WCHAR *domain,
                                      const WCHAR *account) {
    if (account == NULL || account[0] == L'\0') {
        /* Nothing was asserted, so nothing can conflict. */
        return TRUE;
    }
    if (user == NULL || user[0] == L'\0') {
        return FALSE;
    }
    if (_wcsicmp(user, account) == 0) {
        return TRUE;
    }
    /* A generic credential may carry the domain inside the user name. */
    {
        const WCHAR *tail = _wcsrchr(user, L'\\');
        if (tail != NULL && tail[1] != L'\0' && _wcsicmp(tail + 1, account) == 0) {
            return TRUE;
        }
    }
    /* Or report the domain separately, which is what the unpack returns. */
    if (domain != NULL && domain[0] != L'\0') {
        const size_t domain_len = wcslen(domain);
        const size_t user_len = wcslen(user);
        WCHAR *joined = (WCHAR *)malloc((domain_len + 1 + user_len + 1) *
                                        sizeof(WCHAR));
        if (joined == NULL) {
            return FALSE;
        }
        memcpy(joined, domain, domain_len * sizeof(WCHAR));
        joined[domain_len] = L'\\';
        memcpy(joined + domain_len + 1, user, user_len * sizeof(WCHAR));
        joined[domain_len + 1 + user_len] = L'\0';
        const BOOL same = _wcsicmp(joined, account) == 0;
        SecureZeroMemory(joined, (domain_len + 1 + user_len + 1) * sizeof(WCHAR));
        free(joined);
        if (same) {
            return TRUE;
        }
    }
    return FALSE;
}

/*
 * Unpack the dialog's buffer into `fields`.
 *
 * The documented limits are tried first because they are the SDK's own answer
 * for how long these fields may be. When they are not enough, the SDK reports
 * the sizes it needs and the call is retried once at exactly those; a second
 * failure is a real failure and not a loop. Every exit leaves `fields` either
 * populated or empty, never half sized.
 */
static nogui_cred_status nogui_cred_unpack(LPVOID packed, DWORD packed_size,
                                           nogui_cred_fields *fields) {
    memset(fields, 0, sizeof(*fields));
    if (!nogui_cred_fields_alloc(fields, NOGUI_CRED_USER_CHARS,
                                 NOGUI_CRED_DOMAIN_CHARS,
                                 NOGUI_CRED_PASSWORD_CHARS)) {
        nogui_cred_fields_release(fields);
        return NOGUI_CRED_FAILED;
    }
    if (nogui_cred_unpack_once(packed, packed_size, fields)) {
        return NOGUI_CRED_OK;
    }
    const DWORD undersize = GetLastError();
    if (undersize != ERROR_INSUFFICIENT_BUFFER) {
        nogui_cred_fields_release(fields);
        return nogui_cred_classify(undersize);
    }

    /* The one documented undersize answer, taken at the sizes the SDK asked
     * for. A zero would mean the SDK wants nothing, which is not a credential. */
    const DWORD user_chars = fields->user_chars;
    const DWORD domain_chars = fields->domain_chars;
    const DWORD password_chars = fields->password_chars;
    nogui_cred_fields_release(fields);
    if (user_chars == 0 || password_chars == 0) {
        return NOGUI_CRED_FAILED;
    }
    if (!nogui_cred_fields_alloc(fields, user_chars, domain_chars,
                                 password_chars)) {
        nogui_cred_fields_release(fields);
        return NOGUI_CRED_FAILED;
    }
    if (nogui_cred_unpack_once(packed, packed_size, fields)) {
        return NOGUI_CRED_OK;
    }
    nogui_cred_status status = nogui_cred_classify(GetLastError());
    nogui_cred_fields_release(fields);
    return status;
}

/*
 * Copy a NUL-terminated wide string into a new owned UTF-8 allocation with a
 * `size_t` header in front of it, so `nogui_cred_free` can wipe the whole block
 * without being handed a size it could get wrong. The result excludes the
 * terminator, because the host's own buffer is NUL-terminated by its length.
 */
static unsigned char *nogui_cred_take_secret(const WCHAR *password, size_t *out_size) {
    const int needed = WideCharToMultiByte(CP_UTF8, 0, password, -1, NULL, 0,
                                           NULL, NULL);
    if (needed <= 1) {
        /* An empty password, or nothing to convert. An empty secret is not
         * smuggled out as a success, and a conversion failure is not reported
         * as a dismissed prompt, which is a different thing entirely. */
        return NULL;
    }
    const size_t payload = (size_t)needed;
    unsigned char *base =
        (unsigned char *)malloc(sizeof(size_t) + payload);
    if (base == NULL) {
        return NULL;
    }
    *(size_t *)(void *)base = sizeof(size_t) + payload;
    unsigned char *data = base + sizeof(size_t);
    const int written =
        WideCharToMultiByte(CP_UTF8, 0, password, -1, (char *)data, needed,
                            NULL, NULL);
    if (written <= 0) {
        SecureZeroMemory(base, sizeof(size_t) + payload);
        free(base);
        return NULL;
    }
    *out_size = (size_t)(payload - 1);
    return data;
}

nogui_cred_status nogui_cred_prompt(const nogui_cred_request *request,
                                    unsigned char **out_blob,
                                    unsigned int *out_size) {
    if (out_blob == NULL || out_size == NULL) {
        return NOGUI_CRED_FAILED;
    }
    /* Cleared before the dialog, not on a success path, so that no early return
     * can hand a caller a pointer into this frame. */
    *out_blob = NULL;
    *out_size = 0;
    if (request == NULL || request->target == NULL ||
        request->target[0] == L'\0') {
        return NOGUI_CRED_FAILED;
    }
    if (!nogui_cred_can_prompt()) {
        return NOGUI_CRED_UNAVAILABLE;
    }

    /*
     * `CREDUI_INFOW` names what the dialog says and nothing else: there is no
     * field for a prefilled account, and the documented way to hand one in, a
     * packed input buffer, also suppresses the dialog entirely. So the account
     * is compared after the fact rather than offered before it.
     */
    CREDUI_INFOW ui;
    SecureZeroMemory(&ui, sizeof(ui));
    ui.cbSize = sizeof(ui);
    ui.hwndParent = (HWND)request->hwnd;
    ui.pszMessageText = request->message;
    ui.pszCaptionText = request->caption;
    ui.hbmBanner = NULL;

    LPVOID packed = NULL;
    ULONG packed_size = 0;
    /*
     * `pvInAuthBuffer` stays NULL so the dialog is shown at all, `ppvOutAuthBuffer`
     * is NULL on entry because the function allocates it, and `pulAuthPackage` is
     * NULL because zero is the documented request for the default package set.
     */
    const DWORD result =
        CredUIPromptForWindowsCredentialsW(&ui, 0, NULL, NULL, 0, &packed,
                                          &packed_size, NULL, NOGUI_CRED_FLAGS);
    if (result != ERROR_SUCCESS) {
        /* A nonzero return is the failure itself and carries the reason. */
        return nogui_cred_classify(result);
    }
    /*
     * `ERROR_SUCCESS` does not mean a credential was produced. The documented
     * contract is that the outcome is in the last error, and
     * `ERROR_CANCELLED` there is the user closing the dialog.
     */
    const DWORD outcome = GetLastError();
    if (outcome != ERROR_SUCCESS) {
        if (packed != NULL) {
            SecureZeroMemory(packed, packed_size);
            CoTaskMemFree(packed);
        }
        return nogui_cred_classify(outcome);
    }
    if (packed == NULL || packed_size == 0) {
        /* Success with nothing in it is not a credential, and reporting it as
         * one would hand the caller an empty secret to store. */
        return NOGUI_CRED_FAILED;
    }

    nogui_cred_fields fields;
    nogui_cred_status status = nogui_cred_unpack(packed, (DWORD)packed_size, &fields);

    /* The packed buffer holds the password in the provider's own encoding, so
     * it is wiped before it is released and not merely released. The documented
     * release for this buffer is `CoTaskMemFree`. */
    SecureZeroMemory(packed, packed_size);
    CoTaskMemFree(packed);

    unsigned char *secret = NULL;
    if (status == NOGUI_CRED_OK) {
        if (!nogui_cred_matches_account(fields.user, fields.domain,
                                         request->account)) {
            /* Refused before any byte crosses back: this secret belongs to an
             * account the caller did not ask about. */
            status = NOGUI_CRED_ACCOUNT_MISMATCH;
        } else {
            size_t size = 0;
            secret = nogui_cred_take_secret(fields.password, &size);
            if (secret == NULL) {
                status = NOGUI_CRED_FAILED;
            } else {
                *out_blob = secret;
                *out_size = (unsigned int)size;
            }
        }
    }

    nogui_cred_fields_release(&fields);
    return status;
}

void nogui_cred_free(void *blob) {
    if (blob == NULL) {
        return;
    }
    unsigned char *base = (unsigned char *)blob - sizeof(size_t);
    const size_t total = *(size_t *)(void *)base;
    /*
     * Wipe before free, over the whole allocation including the header. A free
     * through the CRT allocator does not promise to scrub, and a password left
     * in freed heap is a password left in the process.
     */
    if (total >= sizeof(size_t)) {
        SecureZeroMemory(base, total);
    }
    free(base);
}
