/*
 * Narrow C ABI over the Windows credential prompt.
 *
 * The prompt is `CredUIPromptForWindowsCredentialsW` from `wincred.h`, and it
 * is the supported entry point. It never writes a credential: it hands back an
 * opaque packed buffer that `CredUnPackAuthenticationBufferW` turns into a user
 * name and a password. Both the pack and the unpack need the SDK's own limits
 * and the `CREDUI_INFOW` layout, so both stay in C and only a status, one owned
 * UTF-8 secret and the account it belongs to cross this boundary.
 *
 * The secret crosses as one owned, NUL-terminated UTF-8 allocation with a length
 * header in front of it, so `nogui_cred_free` can wipe without being handed a
 * size it could get wrong. The caller copies it into memory it owns and then
 * releases this one, so the only copy that outlives the call is one the caller
 * can zero.
 */
#ifndef NOGUI_CREDUI_H
#define NOGUI_CREDUI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors `PromptStatus` in src/v7_host/windows/credentials.zig. The values
 * are a wire contract between the two, so they are spelled out rather than
 * shared through a generated header. */
typedef enum nogui_cred_status {
    NOGUI_CRED_OK = 0,
    /* The user closed the dialog. A dismissed prompt, which the host contract
     * keeps distinct from the app's own cancellation token. */
    NOGUI_CRED_CANCELLED = 1,
    /* The user or policy refused this credential: access denied, a bad
     * password, an account the logon will not take. */
    NOGUI_CRED_DENIED = 2,
    /* The store owns the credential but no logon session can use it yet:
     * no session, an expired password, a disabled account. */
    NOGUI_CRED_LOCKED = 3,
    /* The call failed for a reason the caller may retry. */
    NOGUI_CRED_FAILED = 4,
    /* No interactive window station, so nothing could have been shown. Named
     * apart from FAILED because no user was ever asked anything. */
    NOGUI_CRED_UNAVAILABLE = 5,
    /* The dialog produced a credential for a different account than the one
     * requested. Refused rather than filed under the requested account, which
     * would store a secret against an account nobody authenticated. */
    NOGUI_CRED_ACCOUNT_MISMATCH = 6
} nogui_cred_status;

typedef struct nogui_cred_request {
    /* Borrowed owner window, or NULL to let CredUI use the desktop. */
    void *hwnd;
    /* The credential's identity in the store, as the dialog's own target line.
     * It is the target name and not a caption: the store keys on it. */
    const wchar_t *target;
    const wchar_t *caption;
    const wchar_t *message;
    /*
     * The account this query is about. The dialog cannot be given a prefilled
     * account: the documented way to hand it one, a packed input buffer, also
     * suppresses the dialog entirely. So this is an expectation, not a
     * prefill, and an answer naming any other account is refused.
     */
    const wchar_t *account;
} nogui_cred_request;

/*
 * Show the prompt and unpack what it produced.
 *
 * On NOGUI_CRED_OK both out-parameters are set to one buffer this library owns,
 * whose contents are the password as NUL-terminated UTF-8 and whose length
 * excludes the terminator. On every other status neither is touched, so a
 * caller that ignores the status reads NULL rather than a stale pointer.
 *
 * Every failure, including allocation failure, is a status code. There is no C++
 * frame and no exception, so nothing can unwind into the caller.
 */
nogui_cred_status nogui_cred_prompt(const nogui_cred_request *request,
                                    unsigned char **out_blob,
                                    unsigned int *out_size);

/*
 * Release a blob from `nogui_cred_prompt`, wiping it first. Safe on NULL.
 *
 * The wipe is not decorative. The password is clear bytes in this process and
 * the block goes back to the CRT allocator, which promises nothing about the
 * memory it returns; without the wipe the bytes stay readable in freed heap
 * until something overwrites them by accident.
 */
void nogui_cred_free(void *blob);

#ifdef __cplusplus
}
#endif

#endif /* NOGUI_CREDUI_H */
