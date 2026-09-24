/*
 * nogui Android shim: the JNI half of the mobile adapters.
 *
 * Why JNI and not a plain C shim. The Android accessibility API is
 * `AccessibilityNodeProvider`, a Java class the framework calls, and every node
 * it hands back is a real `AccessibilityNodeInfo`. There is no C entry point
 * that produces either, so the bridge is reached from the Java side in
 * `NoguiAccessibilityProvider.java`: the framework talks to that object, and it
 * calls back into the JNI functions at the bottom of this file. Those use the
 * name mangling the toolchain generates for a Java `native` method, so the Java
 * declaration and the C definition are one contract rather than a hand-written
 * table that could drift.
 *
 * Built by `zig cc` as C against the NDK, for Android only. The Zig side gates
 * every call on the Android ABI — `comptime builtin.abi.isAndroid()`, not an
 * operating-system tag, because Android in Zig is the `.linux` OS tag with an
 * android ABI, and there is no `.android` OS tag to test for — so a build for
 * any other target never references a symbol this file defines.
 *
 * ── What this file is careful about ────────────────────────────────────────
 *
 * 1. IDENTITY IS A NAME, NOT A POSITION. A node's `native_id` is the core's
 *    stable identity and is what the platform holds. It arrives in each node of
 *    an update, and the shim keys everything by it: a sorted table resolves an
 *    id the framework hands back to the dense index that currently carries that
 *    id, and an id no live node carries produces no node, no request and no
 *    action. A dense index could not do that. An index still in range after a
 *    removal addresses whatever node moved into it, and a screen reader would
 *    then drive the wrong control.
 *
 * 2. AN UPDATE IS A WHOLE TREE OR NOTHING. The caller's buffers are borrowed for
 *    the update call and the framework asks about these facts long after it
 *    returned, so the shim takes its own copy of every node, string and custom
 *    action. The new tree is built completely, then swapped in under the lock,
 *    and only then is the old one released. A framework call therefore sees
 *    either the whole previous tree or the whole new one, never half of either.
 *
 * 3. UI-THREAD WORK IS MARSHALLED, NOT REFUSED. SDL's native main thread is not
 *    Android's UI thread, so refusing every call made from it would make the
 *    shim useless rather than safe. Anything that touches the window, the
 *    activity or a view is posted to the UI thread through the Java half and
 *    waited for under a bound; a bound that is not met is a refusal. The JNI
 *    entry points at the bottom are the exception: the framework calls those on
 *    its own accessibility thread and requires an answer there, so they are
 *    guarded by the lock and by the table of live bridges instead.
 *
 * 4. EVERY JNI BORROW IS RELEASED. A local reference lives until the native
 *    frame returns, and an unreleased one in a per-node loop exhausts the local
 *    reference table. Strings, arrays and objects this file obtains are released
 *    on every path out, including the refusal paths.
 *
 * 5. A FREE THAT RACES A FRAMEWORK CALL WAITS. The pointer a Java provider holds
 *    is only ever dereferenced after it has been found in a table of live
 *    bridges, under the lock, with a reference taken. `nogui_android_a11y_free`
 *    removes the bridge from that table first, so no new call can find it, and
 *    then waits for the calls already inside to leave. A provider that outlives
 *    the bridge therefore answers "no node" rather than reaching freed memory.
 *
 * ── Units ──────────────────────────────────────────────────────────────────
 *
 * On Android every rectangle crossing this ABI is in PHYSICAL SDL-WINDOW
 * PIXELS, which is the space the framework's own `WindowInsets` and
 * `setBoundsInScreen` speak and the space the host's observer divides by the
 * scale it actually observed. This file therefore applies no scale of its own:
 * the insets and the keyboard frame are returned exactly as the framework
 * measured them, and a node's published bounds go to `setBoundsInScreen`
 * unchanged.
 *
 * In particular there is no display-density conversion here, and there must not
 * be one. Display density is not the scale SDL is rendering at — an app can run
 * with `pixelScale` 1 on a display whose density is 3 — so converting by it
 * would put every node at the wrong size and a screen reader's highlight on the
 * wrong control. The host owns that number because it is the only layer that
 * observed it.
 *
 * The one origin this file adds is the host view's real position on screen,
 * read from the framework at attach. A node's bounds are relative to the window,
 * while the framework wants them relative to the screen, and the difference is
 * the surface view's own location — measured, not assumed, because a decor view
 * sitting below a status bar has an origin that is not the surface's.
 */
#include <jni.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "nogui_mobile.h"

/* ── the process lock ─────────────────────────────────────────────────────── */

/*
 * One lock, because the accessibility thread and the UI thread read and write
 * the same bridge, and because it is also what makes a free safe: a bridge is
 * only ever reached after it has been found in a table of live bridges while the
 * lock is held. It is recursive so a helper may be called from a section that
 * already holds it, which keeps one discipline — a function that takes the lock
 * releases it, and nothing else takes it.
 */
static pthread_mutex_t nogui_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
static pthread_cond_t nogui_drained = PTHREAD_COND_INITIALIZER;

static void nogui_lock_acquire(void)
{
    pthread_mutex_lock(&nogui_lock);
}

static void nogui_lock_release(void)
{
    pthread_mutex_unlock(&nogui_lock);
}

/*
 * The table of live bridges.
 *
 * A Java provider holds a bare pointer, and a pointer outlives the thing it
 * points at unless something says otherwise. Every JNI entry point looks the
 * handle up here before it touches it, which turns "this pointer used to be
 * valid" into "this pointer is valid right now". A handle that is not in the
 * table is answered as absent, which is what a provider that outlived its bridge
 * must say.
 *
 * Four slots is four simultaneous mobile bridges: one per process in practice,
 * since an Android app has one activity and one accessibility hierarchy. The
 * table is deliberately small and static, so it has the same lifetime as the
 * process and can never be freed out from under a waiting thread.
 */
#define NOGUI_ANDROID_SLOTS 4

static nogui_mobile_bridge *nogui_android_slots[NOGUI_ANDROID_SLOTS];
static int32_t nogui_android_slot_refs[NOGUI_ANDROID_SLOTS];

/* Claim a handle for the duration of one framework call. */
static nogui_mobile_bridge *nogui_android_claim(intptr_t handle, int32_t *out_slot)
{
    nogui_lock_acquire();
    nogui_mobile_bridge *found = NULL;
    for (int32_t slot = 0; slot < NOGUI_ANDROID_SLOTS; ++slot) {
        nogui_mobile_bridge *bridge = nogui_android_slots[slot];
        if (bridge != NULL && (intptr_t)bridge == handle && !bridge->dead) {
            nogui_android_slot_refs[slot] += 1;
            *out_slot = slot;
            found = bridge;
            break;
        }
    }
    nogui_lock_release();
    return found;
}

static void nogui_android_unclaim(int32_t slot)
{
    nogui_lock_acquire();
    if (nogui_android_slot_refs[slot] > 0) {
        nogui_android_slot_refs[slot] -= 1;
        if (nogui_android_slot_refs[slot] == 0 && nogui_android_slots[slot] == NULL) {
            /* A free is waiting for exactly this. */
            pthread_cond_broadcast(&nogui_drained);
        }
    }
    nogui_lock_release();
}

/* Register a freshly created bridge, or report that there is no room. */
static int32_t nogui_android_publish(nogui_mobile_bridge *bridge)
{
    nogui_lock_acquire();
    int32_t placed = NOGUI_MOBILE_ERR_MEMORY;
    for (int32_t slot = 0; slot < NOGUI_ANDROID_SLOTS; ++slot) {
        if (nogui_android_slots[slot] == NULL) {
            nogui_android_slots[slot] = bridge;
            bridge->slot = slot;
            placed = NOGUI_MOBILE_OK;
            break;
        }
    }
    nogui_lock_release();
    return placed;
}

/* ── UTF-8 and UTF-16 ─────────────────────────────────────────────────────── */

/*
 * The conversion runs in both directions and neither side is allowed to guess.
 *
 * Java strings are UTF-16. A Java `String` holds a supplementary character as a
 * surrogate pair, and `GetStringUTFChars` returns MODIFIED UTF-8, in which a
 * supplementary character is six bytes and a NUL inside the string is two. A
 * value edited by a screen reader arrives through that path, and a payload read
 * as a C string — which the old code did — would be truncated at the first NUL
 * and would carry a six-byte sequence where the core expects four. So action text
 * is read with `GetStringLength` plus `GetStringChars` and converted here, with
 * an explicit length in both directions.
 *
 * A lone surrogate has no UTF-8 form. Java substitutes U+FFFD for one when it
 * decodes, and so does this: a screen reader that typed half an emoji and lost
 * the frame boundary still gets its text into the model, visibly marked as the
 * damaged character, rather than having the whole edit refused.
 */
#define NOGUI_ANDROID_REPLACEMENT 0xFFFDu

/*
 * Bytes one UTF-8 sequence at `at` occupies, or 0 when it is malformed.
 *
 * Overlong forms, a surrogate encoded as UTF-8, and anything past the last code
 * point are all rejected. Each of those has more than one byte sequence that
 * would decode to the same value, which is exactly the ambiguity that lets two
 * different strings become one.
 */
static size_t nogui_utf8_step(const char *text, size_t len, size_t at, uint32_t *out)
{
    if (at >= len) {
        return 0;
    }
    unsigned char lead = (unsigned char)text[at];
    if (lead < 0x80u) {
        *out = lead;
        return 1;
    }
    size_t extra;
    uint32_t cp;
    if ((lead & 0xE0u) == 0xC0u) {
        extra = 1;
        cp = lead & 0x1Fu;
    } else if ((lead & 0xF0u) == 0xE0u) {
        extra = 2;
        cp = lead & 0x0Fu;
    } else if ((lead & 0xF8u) == 0xF0u) {
        extra = 3;
        cp = lead & 0x07u;
    } else {
        /* A continuation byte, or a five-byte form: neither starts a sequence. */
        return 0;
    }
    if (len - at <= extra) {
        return 0;
    }
    for (size_t step = 1; step <= extra; ++step) {
        unsigned char next = (unsigned char)text[at + step];
        if ((next & 0xC0u) != 0x80u) {
            return 0;
        }
        cp = (cp << 6) | (next & 0x3Fu);
    }
    if ((extra == 1 && cp < 0x80u) || (extra == 2 && cp < 0x800u) || (extra == 3 && cp < 0x10000u)) {
        return 0;
    }
    if (cp > 0x10FFFFu || (cp >= 0xD800u && cp <= 0xDFFFu)) {
        return 0;
    }
    *out = cp;
    return extra + 1;
}

/*
 * Normal UTF-8 to UTF-16, for a Java string the shim creates.
 *
 * Malformed input is refused rather than repaired: a repaired label is a
 * different label, and the caller learns about it through `status` instead of
 * announcing a string the app never published. The buffer is bounded by the
 * input, because no UTF-8 sequence yields more UTF-16 units than it has bytes.
 */
static uint16_t *nogui_utf16_from_utf8(const char *utf8, size_t len, size_t *out_units, int32_t *status)
{
    *out_units = 0;
    *status = NOGUI_MOBILE_OK;
    if (utf8 == NULL) {
        return NULL;
    }
    if (len > NOGUI_MOBILE_MAX_TEXT) {
        *status = NOGUI_MOBILE_ERR_BUFFER;
        return NULL;
    }
    uint16_t *units = (uint16_t *)malloc((len + 1) * sizeof(*units));
    if (units == NULL) {
        *status = NOGUI_MOBILE_ERR_MEMORY;
        return NULL;
    }
    size_t at = 0;
    size_t used = 0;
    while (at < len) {
        uint32_t cp = 0;
        size_t step = nogui_utf8_step(utf8, len, at, &cp);
        if (step == 0) {
            free(units);
            *status = NOGUI_MOBILE_ERR_ARGUMENT;
            return NULL;
        }
        if (cp < 0x10000u) {
            units[used++] = (uint16_t)cp;
        } else {
            cp -= 0x10000u;
            units[used++] = (uint16_t)(0xD800u | (cp >> 10));
            units[used++] = (uint16_t)(0xDC00u | (cp & 0x3FFu));
        }
        at += step;
    }
    *out_units = used;
    return units;
}

/* UTF-16 to normal UTF-8, for a Java string the shim reads. */
static int32_t nogui_utf8_from_utf16(
    const uint16_t *units,
    size_t unit_len,
    char *out,
    size_t cap,
    size_t *out_len)
{
    size_t used = 0;
    for (size_t at = 0; at < unit_len;) {
        uint32_t cp = units[at];
        if (cp >= 0xD800u && cp <= 0xDBFFu && at + 1 < unit_len
                && units[at + 1] >= 0xDC00u && units[at + 1] <= 0xDFFFu) {
            cp = 0x10000u + ((cp - 0xD800u) << 10) + (units[at + 1] - 0xDC00u);
            at += 2;
        } else {
            if (cp >= 0xD800u && cp <= 0xDFFFu) {
                cp = NOGUI_ANDROID_REPLACEMENT;
            }
            at += 1;
        }
        char encoded[4];
        size_t width;
        if (cp < 0x80u) {
            encoded[0] = (char)cp;
            width = 1;
        } else if (cp < 0x800u) {
            encoded[0] = (char)(0xC0u | (cp >> 6));
            encoded[1] = (char)(0x80u | (cp & 0x3Fu));
            width = 2;
        } else if (cp < 0x10000u) {
            encoded[0] = (char)(0xE0u | (cp >> 12));
            encoded[1] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            encoded[2] = (char)(0x80u | (cp & 0x3Fu));
            width = 3;
        } else {
            encoded[0] = (char)(0xF0u | (cp >> 18));
            encoded[1] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
            encoded[2] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            encoded[3] = (char)(0x80u | (cp & 0x3Fu));
            width = 4;
        }
        if (used + width + 1 > cap) {
            return NOGUI_MOBILE_ERR_BUFFER;
        }
        memcpy(out + used, encoded, width);
        used += width;
    }
    out[used] = '\0';
    *out_len = used;
    return NOGUI_MOBILE_OK;
}

/* A jstring holding `utf8`, or null with `status` naming the refusal. */
static jstring nogui_jstring(JNIEnv *env, const char *utf8, size_t len, int32_t *status)
{
    *status = NOGUI_MOBILE_OK;
    if (utf8 == NULL || len == 0) {
        return NULL;
    }
    size_t units = 0;
    uint16_t *wide = nogui_utf16_from_utf8(utf8, len, &units, status);
    if (wide == NULL) {
        return NULL;
    }
    /* `NewString` takes an explicit length, so a NUL inside the text is a
     * character in the string rather than the end of it. `NewStringUTF` would
     * stop at the first NUL and would turn any supplementary character into the
     * modified six-byte form, which is not the text the app published. */
    jstring result = (*env)->NewString(env, wide, (jsize)units);
    free(wide);
    if ((*env)->ExceptionCheck(env) || result == NULL) {
        (*env)->ExceptionClear(env);
        *status = NOGUI_MOBILE_ERR_MEMORY;
        return NULL;
    }
    return result;
}

/*
 * Whether the framework raised on a call, and cleared.
 *
 * A Java exception left pending when a native frame returns is a hard crash on
 * the next JNI call, so every call this file makes is followed by clearing one.
 * It is declared before the helpers that need it rather than beside the member
 * table, so the conversion code above does not have to know where the rest of
 * the JNI plumbing lives.
 */
static void nogui_clear_exception(JNIEnv *env)
{
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
}

/* Set a text-bearing property from a borrowed UTF-8 slice, if there is one. */
static void nogui_set_text(
    JNIEnv *env,
    jmethodID setter,
    jobject node,
    const char *utf8,
    size_t len)
{
    if (setter == NULL || utf8 == NULL || len == 0) {
        return;
    }
    int32_t status = NOGUI_MOBILE_OK;
    jstring value = nogui_jstring(env, utf8, len, &status);
    if (value == NULL) {
        /* The slice is not text the platform can state. Leaving the property
         * unset is the refusal: announcing a repaired string would be a
         * different string. */
        return;
    }
    (*env)->CallVoidMethod(env, node, setter, value);
    nogui_clear_exception(env);
    (*env)->DeleteLocalRef(env, value);
}

/* ── JNI member table ────────────────────────────────────────────────────── */

/*
 * Everything the bridge needs, resolved once at attach.
 *
 * A member absent on this API level stays null, and the code that would have
 * used it reports NOGUI_MOBILE_ERR_UNAVAILABLE. That is deliberate: an old
 * device is a named refusal rather than a crash halfway through a publish, and
 * the caller can tell "this platform cannot do that" from "the app published
 * nothing".
 *
 * The framework's action ids are read rather than written here. The standard
 * actions are compile-time constants, but the ones a virtual tree needs — show
 * on screen, scroll to position, set progress — are `R.id`-backed
 * `AccessibilityAction` singletons whose numeric values are resource ids and
 * differ between releases. Reading the value the running framework uses is the
 * only way to compare it against what that framework later hands back.
 */
struct nogui_android_jni {
    jclass activity_class;
    /* `Activity.moveTaskToBack`, which is what Android does with a back press
     * no activity consumed. It belongs to the UI thread like everything else
     * the activity owns, so it is reached through the hop below. */
    jmethodID activity_move_task_to_back;
    jclass window_class;
    jmethodID window_get_decor;
    jclass view_class;
    jmethodID view_get_width;
    jmethodID view_get_height;
    jmethodID view_get_root_insets;
    jmethodID view_get_inset_top;
    jmethodID view_get_inset_left;
    jmethodID view_get_inset_bottom;
    jmethodID view_get_inset_right;
    jclass insets_type_class;
    jfieldID type_ime;
    jfieldID type_status_bars;
    jfieldID type_navigation_bars;
    jfieldID type_caption_bar;
    jfieldID type_display_cutout;
    jclass window_insets_class;
    jmethodID insets_get_insets;
    jmethodID insets_is_visible;
    jclass event_class;
    jclass provider_class;
    jmethodID provider_ctor;
    jmethodID provider_stage;
    jmethodID provider_install;
    jmethodID provider_installed_host;
    jmethodID provider_host_origin;
    jmethodID provider_uninstall;
    jmethodID provider_measure;
    jmethodID provider_content_changed;
    jclass node_info_class;
    jmethodID node_info_obtain_host;
    jmethodID node_info_set_class_name;
    jmethodID node_info_set_text;
    jmethodID node_info_set_content_description;
    jmethodID node_info_set_hint_text;
    jmethodID node_info_set_package_name;
    jmethodID node_info_set_bounds_in_screen;
    jmethodID node_info_set_enabled;
    jmethodID node_info_set_focusable;
    jmethodID node_info_set_focused;
    jmethodID node_info_set_selected;
    jmethodID node_info_set_checkable;
    jmethodID node_info_set_checked;
    jmethodID node_info_set_editable;
    jmethodID node_info_set_visible_to_user;
    jmethodID node_info_set_content_invalid;
    jmethodID node_info_set_live_region;
    jmethodID node_info_set_text_selection;
    jmethodID node_info_set_view_id;
    jmethodID node_info_add_action;
    jmethodID node_info_add_child;
    jmethodID node_info_set_collection_info;
    jmethodID node_info_set_collection_item_info;
    jmethodID node_info_set_range_info;
    jclass action_class;
    jmethodID action_ctor;
    jclass rect_class;
    jmethodID rect_ctor;
    jclass range_info_class;
    jmethodID range_info_obtain;
    jmethodID range_info_set_min;
    jmethodID range_info_set_max;
    jmethodID range_info_set_current;
    jclass collection_info_class;
    jmethodID collection_info_obtain;
    jmethodID collection_info_set_row_count;
    jmethodID collection_info_set_row_index;
    jmethodID collection_info_set_column_count;
    jmethodID collection_info_set_row_index_is_set;
    jclass collection_item_info_class;
    jmethodID collection_item_info_obtain;
    jmethodID collection_item_info_set_row_index;
    jmethodID collection_item_info_set_row_count;
    /* The framework's own action ids, read at attach. Zero means the running
     * framework does not have that action at all. */
    jint action_focus;
    jint action_clear_focus;
    jint action_click;
    jint action_scroll_forward;
    jint action_scroll_backward;
    jint action_set_selection;
    jint action_expand;
    jint action_collapse;
    jint action_set_text;
    jint action_show_on_screen;
    jint action_set_progress;
    jint event_content_changed;
    jint live_region_polite;
};

static jclass nogui_global_class(JNIEnv *env, const char *name)
{
    jclass local = (*env)->FindClass(env, name);
    if (local == NULL) {
        (*env)->ExceptionClear(env);
        return NULL;
    }
    jclass global = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (global == NULL) {
        (*env)->ExceptionClear(env);
    }
    return global;
}

static jmethodID nogui_method(JNIEnv *env, jclass type, const char *name, const char *sig)
{
    if (type == NULL) {
        return NULL;
    }
    jmethodID method = (*env)->GetMethodID(env, type, name, sig);
    if (method == NULL) {
        (*env)->ExceptionClear(env);
    }
    return method;
}

static jmethodID nogui_static_method(JNIEnv *env, jclass type, const char *name, const char *sig)
{
    if (type == NULL) {
        return NULL;
    }
    jmethodID method = (*env)->GetStaticMethodID(env, type, name, sig);
    if (method == NULL) {
        (*env)->ExceptionClear(env);
    }
    return method;
}

static jfieldID nogui_field(JNIEnv *env, jclass type, const char *name, const char *sig)
{
    if (type == NULL) {
        return NULL;
    }
    jfieldID field = (*env)->GetFieldID(env, type, name, sig);
    if (field == NULL) {
        (*env)->ExceptionClear(env);
    }
    return field;
}

static jfieldID nogui_static_field(JNIEnv *env, jclass type, const char *name, const char *sig)
{
    if (type == NULL) {
        return NULL;
    }
    jfieldID field = (*env)->GetStaticFieldID(env, type, name, sig);
    if (field == NULL) {
        (*env)->ExceptionClear(env);
    }
    return field;
}

/* Read one public static int, or 0 when this framework does not have it. */
static jint nogui_static_int(JNIEnv *env, jclass type, const char *name)
{
    jfieldID field = nogui_static_field(env, type, name, "I");
    if (field == NULL) {
        return 0;
    }
    return (*env)->GetStaticIntField(env, type, field);
}

/*
 * The id of a framework action that is an `R.id`-backed `AccessibilityAction`
 * rather than an int constant. Reading it off the singleton is the only way to
 * learn the value the running framework will hand back later. Zero means the
 * action does not exist here, and every use of it is then a refusal.
 */
static jint nogui_named_action_id(JNIEnv *env, struct nogui_android_jni *jni, const char *name)
{
    if (jni->action_class == NULL) {
        return 0;
    }
    jfieldID field = nogui_static_field(
        env, jni->action_class, name,
        "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;");
    if (field == NULL) {
        return 0;
    }
    jobject action = (*env)->GetStaticObjectField(env, jni->action_class, field);
    if ((*env)->ExceptionCheck(env) || action == NULL) {
        nogui_clear_exception(env);
        return 0;
    }
    jint id = 0;
    jmethodID get_id = nogui_method(env, jni->action_class, "getId", "()I");
    if (get_id != NULL) {
        id = (*env)->CallIntMethod(env, action, get_id);
        nogui_clear_exception(env);
    }
    (*env)->DeleteLocalRef(env, action);
    return id;
}

/*
 * E04 resolution: the window facts and the UI-thread hop they are read on.
 *
 * The safe area, the soft keyboard and the window's own geometry exist with or
 * without an accessibility provider, so they are resolved on their own terms
 * here. The one member that IS shared is `provider_measure`, because it is the
 * hop onto the UI thread and every member below belongs to that thread. Its
 * class is E05's, its hop is not: requiring the provider's constructor, its
 * install methods and its node members here made every safe-area and keyboard
 * read refuse on any app that had not compiled the E05 half, which turned two
 * independent features into one.
 */
static int32_t nogui_resolve_window(JNIEnv *env, struct nogui_android_jni *jni)
{
    memset(jni, 0, sizeof(*jni));

    jni->activity_class = nogui_global_class(env, "android/app/Activity");
    jni->window_class = nogui_global_class(env, "android/view/Window");
    jni->view_class = nogui_global_class(env, "android/view/View");
    jni->insets_type_class = nogui_global_class(env, "android/view/WindowInsets$Type");
    jni->window_insets_class = nogui_global_class(env, "android/view/WindowInsets");
    jni->event_class = nogui_global_class(env, "android/view/accessibility/AccessibilityEvent");
    jni->provider_class = nogui_global_class(env, "org/libsdl/app/NoguiAccessibilityProvider");

    if (jni->provider_class == NULL || jni->view_class == NULL || jni->window_class == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }

    jni->window_get_decor = nogui_method(env, jni->window_class, "getDecorView", "()Landroid/view/View;");
    jni->view_get_width = nogui_method(env, jni->view_class, "getWidth", "()I");
    jni->view_get_height = nogui_method(env, jni->view_class, "getHeight", "()I");
    jni->view_get_root_insets = nogui_method(
        env, jni->view_class, "getRootWindowInsets", "()Landroid/view/WindowInsets;");
    jni->view_get_inset_top = nogui_method(env, jni->view_class, "getSystemWindowInsetTop", "()I");
    jni->view_get_inset_left = nogui_method(env, jni->view_class, "getSystemWindowInsetLeft", "()I");
    jni->view_get_inset_bottom = nogui_method(env, jni->view_class, "getSystemWindowInsetBottom", "()I");
    jni->view_get_inset_right = nogui_method(env, jni->view_class, "getSystemWindowInsetRight", "()I");

    /* `WindowInsets.Type` arrived with API 30. Below it the class is absent,
     * and every use of the input method below is then a refusal rather than a
     * guess about a keyboard nobody measured. */
    jni->type_ime = nogui_static_field(env, jni->insets_type_class, "ime", "I");
    jni->type_status_bars = nogui_static_field(env, jni->insets_type_class, "statusBars", "I");
    jni->type_navigation_bars = nogui_static_field(env, jni->insets_type_class, "navigationBars", "I");
    jni->type_caption_bar = nogui_static_field(env, jni->insets_type_class, "captionBar", "I");
    jni->type_display_cutout = nogui_static_field(env, jni->insets_type_class, "displayCutout", "I");
    jni->insets_get_insets = nogui_method(
        env, jni->window_insets_class, "getInsets", "(I)Landroid/graphics/Rect;");
    jni->insets_is_visible = nogui_method(env, jni->window_insets_class, "isVisible", "(I)Z");

    jni->event_content_changed = nogui_static_int(
        env, jni->event_class, "TYPE_WINDOW_CONTENT_CHANGED");
    jni->live_region_polite = nogui_static_int(env, jni->view_class, "LIVE_REGION_POLITE");

    /* The UI-thread hop. The measurement is taken by the posted runnable and
     * read back through these arrays, which is how a value crosses from the
     * thread that owns the decor view to the one that asked for it. */
    jni->provider_measure = nogui_static_method(
        env, jni->provider_class, "measureOnUiThread",
        "(Landroid/app/Activity;I[J[D)I");

    jni->activity_move_task_to_back = nogui_method(
        env, jni->activity_class, "moveTaskToBack", "(Z)Z");

    if (jni->window_get_decor == NULL || jni->provider_measure == NULL
        || jni->activity_move_task_to_back == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    return NOGUI_MOBILE_OK;
}

/* E05 resolution: everything the published tree needs, on top of the window. */
static int32_t nogui_resolve_bridge(JNIEnv *env, struct nogui_android_jni *jni)
{
    int32_t status = nogui_resolve_window(env, jni);
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }

    jni->node_info_class = nogui_global_class(env, "android/view/accessibility/AccessibilityNodeInfo");
    jni->action_class = nogui_global_class(
        env, "android/view/accessibility/AccessibilityNodeInfo$AccessibilityAction");
    jni->rect_class = nogui_global_class(env, "android/graphics/Rect");
    jni->range_info_class = nogui_global_class(
        env, "android/view/accessibility/AccessibilityNodeInfo$RangeInfo");
    jni->collection_info_class = nogui_global_class(
        env, "android/view/accessibility/AccessibilityNodeInfo$CollectionInfo");
    jni->collection_item_info_class = nogui_global_class(
        env, "android/view/accessibility/AccessibilityNodeInfo$CollectionItemInfo");

    if (jni->node_info_class == NULL || jni->rect_class == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }

    /* The provider is created here, by ordinary JNI, before the hop; the posted
     * runnable then does nothing but view work. The install and the removal are
     * static Java methods because they need the UI thread and nothing else, and
     * keeping them here means a hop that lands late touches only Java objects. */
    jni->provider_ctor = nogui_method(env, jni->provider_class, "<init>", "()V");
    jni->provider_stage = nogui_static_method(
        env, jni->provider_class, "stageForInstall",
        "(Lorg/libsdl/app/NoguiAccessibilityProvider;)V");
    jni->provider_install = nogui_static_method(
        env, jni->provider_class, "installOnUiThread",
        "(Landroid/app/Activity;J)I");
    jni->provider_installed_host = nogui_static_method(
        env, jni->provider_class, "installedHost", "()Landroid/view/View;");
    jni->provider_host_origin = nogui_static_method(
        env, jni->provider_class, "hostOrigin", "()[I");
    jni->provider_uninstall = nogui_static_method(
        env, jni->provider_class, "uninstallOnUiThread",
        "(Landroid/app/Activity;Landroid/view/View;)V");
    jni->provider_content_changed = nogui_static_method(
        env, jni->provider_class, "postContentChanged",
        "(Landroid/app/Activity;Landroid/view/View;I)V");

    jni->node_info_obtain_host = nogui_static_method(
        env, jni->node_info_class, "obtain",
        "(Landroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;");
    jni->node_info_set_class_name = nogui_method(
        env, jni->node_info_class, "setClassName", "(Ljava/lang/CharSequence;)V");
    jni->node_info_set_text = nogui_method(
        env, jni->node_info_class, "setText", "(Ljava/lang/CharSequence;)V");
    jni->node_info_set_content_description = nogui_method(
        env, jni->node_info_class, "setContentDescription", "(Ljava/lang/CharSequence;)V");
    jni->node_info_set_hint_text = nogui_method(
        env, jni->node_info_class, "setHintText", "(Ljava/lang/CharSequence;)V");
    jni->node_info_set_package_name = nogui_method(
        env, jni->node_info_class, "setPackageName", "(Ljava/lang/String;)V");
    jni->node_info_set_bounds_in_screen = nogui_method(
        env, jni->node_info_class, "setBoundsInScreen", "(Landroid/graphics/Rect;)V");
    jni->node_info_set_enabled = nogui_method(env, jni->node_info_class, "setEnabled", "(Z)V");
    jni->node_info_set_focusable = nogui_method(env, jni->node_info_class, "setFocusable", "(Z)V");
    jni->node_info_set_focused = nogui_method(env, jni->node_info_class, "setFocused", "(Z)V");
    jni->node_info_set_selected = nogui_method(env, jni->node_info_class, "setSelected", "(Z)V");
    jni->node_info_set_checkable = nogui_method(env, jni->node_info_class, "setCheckable", "(Z)V");
    jni->node_info_set_checked = nogui_method(env, jni->node_info_class, "setChecked", "(Z)V");
    jni->node_info_set_editable = nogui_method(env, jni->node_info_class, "setEditable", "(Z)V");
    jni->node_info_set_visible_to_user = nogui_method(
        env, jni->node_info_class, "setVisibleToUser", "(Z)V");
    jni->node_info_set_content_invalid = nogui_method(
        env, jni->node_info_class, "setContentInvalid", "(Z)V");
    jni->node_info_set_live_region = nogui_method(env, jni->node_info_class, "setLiveRegion", "(I)V");
    jni->node_info_set_text_selection = nogui_method(
        env, jni->node_info_class, "setTextSelection", "(II)V");
    jni->node_info_set_view_id = nogui_method(
        env, jni->node_info_class, "setViewIdResourceName", "(Ljava/lang/String;)V");
    jni->node_info_add_action = nogui_method(
        env, jni->node_info_class, "addAction",
        "(Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;)V");
    jni->node_info_add_child = nogui_method(
        env, jni->node_info_class, "addChild", "(Landroid/view/View;I)V");
    jni->node_info_set_collection_info = nogui_method(
        env, jni->node_info_class, "setCollectionInfo",
        "(Landroid/view/accessibility/AccessibilityNodeInfo$CollectionInfo;)V");
    jni->node_info_set_collection_item_info = nogui_method(
        env, jni->node_info_class, "setCollectionItemInfo",
        "(Landroid/view/accessibility/AccessibilityNodeInfo$CollectionItemInfo;)V");
    jni->node_info_set_range_info = nogui_method(
        env, jni->node_info_class, "setRangeInfo",
        "(Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;)V");
    jni->action_ctor = nogui_method(env, jni->action_class, "<init>", "(ILjava/lang/CharSequence;)V");
    jni->rect_ctor = nogui_method(env, jni->rect_class, "<init>", "(IIII)V");
    jni->range_info_obtain = nogui_static_method(
        env, jni->range_info_class, "obtain",
        "()Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;");
    jni->range_info_set_min = nogui_method(env, jni->range_info_class, "setMin", "(F)V");
    jni->range_info_set_max = nogui_method(env, jni->range_info_class, "setMax", "(F)V");
    jni->range_info_set_current = nogui_method(env, jni->range_info_class, "setCurrent", "(F)V");
    jni->collection_info_obtain = nogui_static_method(
        env, jni->collection_info_class, "obtain",
        "()Landroid/view/accessibility/AccessibilityNodeInfo$CollectionInfo;");
    jni->collection_info_set_row_count = nogui_method(
        env, jni->collection_info_class, "setRowCount", "(I)V");
    jni->collection_info_set_row_index = nogui_method(
        env, jni->collection_info_class, "setRowIndex", "(I)V");
    jni->collection_info_set_column_count = nogui_method(
        env, jni->collection_info_class, "setColumnCount", "(I)V");
    jni->collection_info_set_row_index_is_set = nogui_method(
        env, jni->collection_info_class, "setRowIndexIsSet", "(Z)V");
    jni->collection_item_info_obtain = nogui_static_method(
        env, jni->collection_item_info_class, "obtain",
        "()Landroid/view/accessibility/AccessibilityNodeInfo$CollectionItemInfo;");
    jni->collection_item_info_set_row_index = nogui_method(
        env, jni->collection_item_info_class, "setRowIndex", "(I)V");
    jni->collection_item_info_set_row_count = nogui_method(
        env, jni->collection_item_info_class, "setRowCount", "(I)V");

    jni->action_focus = nogui_static_int(env, jni->node_info_class, "ACTION_FOCUS");
    jni->action_clear_focus = nogui_static_int(env, jni->node_info_class, "ACTION_CLEAR_FOCUS");
    jni->action_click = nogui_static_int(env, jni->node_info_class, "ACTION_CLICK");
    jni->action_scroll_forward = nogui_static_int(env, jni->node_info_class, "ACTION_SCROLL_FORWARD");
    jni->action_scroll_backward = nogui_static_int(env, jni->node_info_class, "ACTION_SCROLL_BACKWARD");
    jni->action_set_selection = nogui_static_int(env, jni->node_info_class, "ACTION_SET_SELECTION");
    jni->action_expand = nogui_static_int(env, jni->node_info_class, "ACTION_EXPAND");
    jni->action_collapse = nogui_static_int(env, jni->node_info_class, "ACTION_COLLAPSE");
    jni->action_set_text = nogui_static_int(env, jni->node_info_class, "ACTION_SET_TEXT");
    jni->action_show_on_screen = nogui_named_action_id(env, jni, "ACTION_SHOW_ON_SCREEN");
    jni->action_set_progress = nogui_named_action_id(env, jni, "ACTION_SET_PROGRESS");

    if (jni->provider_ctor == NULL || jni->provider_stage == NULL || jni->provider_install == NULL
        || jni->provider_installed_host == NULL || jni->provider_host_origin == NULL
        || jni->provider_uninstall == NULL
        || jni->node_info_obtain_host == NULL || jni->node_info_add_child == NULL
        || jni->rect_ctor == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    return NOGUI_MOBILE_OK;
}

static void nogui_release_jni(JNIEnv *env, struct nogui_android_jni *jni)
{
    if (env == NULL) {
        return;
    }
    jclass *classes[] = {
        &jni->activity_class, &jni->window_class, &jni->view_class, &jni->insets_type_class,
        &jni->window_insets_class, &jni->event_class, &jni->provider_class, &jni->node_info_class,
        &jni->action_class, &jni->rect_class, &jni->range_info_class, &jni->collection_info_class,
        &jni->collection_item_info_class,
    };
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); ++i) {
        if (*classes[i] != NULL) {
            (*env)->DeleteGlobalRef(env, *classes[i]);
            *classes[i] = NULL;
        }
    }
}

/* ── the published tree ───────────────────────────────────────────────────── */

/*
 * One published tree, copied whole.
 *
 * `nodes` is a copy of the caller's array with every borrowed pointer repointed
 * into `strings` and with the dense `children` slice cleared, because the
 * children are materialised once, as native ids, in `child_ids`. That is what
 * lets the framework walk the tree by id, and it means nothing the framework
 * asks about later reaches a buffer the adapter has already recycled.
 *
 * `order` holds every dense index sorted by the node's native id, so resolving
 * an id the framework hands back is a binary search rather than a scan of the
 * whole tree on every question.
 */
typedef struct nogui_android_tree {
    size_t len;
    nogui_mobile_node *nodes;
    nogui_mobile_custom_action *customs;
    char *strings;
    int32_t *child_ids;
    int32_t *child_start;
    int32_t *member_id;
    int32_t *order;
    int32_t root;
    int32_t focus;
    int32_t initialized;
} nogui_android_tree;

struct nogui_mobile_bridge {
    void *user;
    nogui_mobile_action_fn on_action;
    nogui_mobile_dirty_fn on_dirty;
    /* The live tree, or null before the first update and after a detach. */
    nogui_android_tree *tree;
    struct nogui_android_jni jni;
    /* SDL's VM, kept so a teardown from any thread can find an environment of
     * its own. The VM is process-wide and a `JNIEnv` is per-thread, so this is
     * the only one of the two that may be stored: an environment obtained on one
     * thread means nothing on another, and a bridge that kept one would hand a
     * foreign thread a pointer it must not dereference. */
    JavaVM *vm;
    /* Global references, because the framework outlives the frame that made
     * them. The activity is SDL's object; the provider and the host view are
     * this file's. */
    jobject activity;
    jobject provider;
    jobject host_view;
    /* The app's real package name, read once at attach. A node announced as
     * belonging to another app would be a lie a screen reader repeats. */
    jstring package_name;
    /* Where the host view sits on the screen, in physical pixels, read from the
     * framework at attach. A node's published bounds are relative to the window
     * while `setBoundsInScreen` wants screen coordinates, and the difference is
     * exactly this. It is measured rather than assumed: a decor view below a
     * status bar has an origin that is not the surface's, and adding one to the
     * other puts every highlight in the wrong place. */
    int32_t origin_x;
    int32_t origin_y;
    int32_t window_focused;
    int32_t attached;
    int32_t dead;
    int32_t slot;
};

/*
 * The platform action id a named action is advertised under.
 *
 * The framework reserves `0xFF000000` for the type of a legacy action mask, its
 * standard ids are all below `0x00200000`, and the actions a virtual tree needs
 * — show on screen, scroll to position, set progress — are resource ids in the
 * `0x01FF0000` range. Nothing the framework owns lives at or above
 * `0x40000000`, so an id built here cannot collide with one, and the range
 * leaves room for far more named actions on one node than any app publishes.
 *
 * The id is the shim's, not the app's. What the app published is an identifier
 * of its own, and it is what the request carries once the slot is resolved.
 */
#define NOGUI_ANDROID_CUSTOM_BASE 0x40000000
#define NOGUI_ANDROID_CUSTOM_LIMIT 0x41000000

static int32_t nogui_custom_action_id(int32_t slot)
{
    if (slot < 0 || slot >= NOGUI_ANDROID_CUSTOM_LIMIT - NOGUI_ANDROID_CUSTOM_BASE) {
        return 0;
    }
    return NOGUI_ANDROID_CUSTOM_BASE + slot;
}

static int32_t nogui_custom_action_slot(int32_t action_id)
{
    if (action_id < NOGUI_ANDROID_CUSTOM_BASE || action_id >= NOGUI_ANDROID_CUSTOM_LIMIT) {
        return -1;
    }
    return action_id - NOGUI_ANDROID_CUSTOM_BASE;
}

/* The dense index that currently carries `native_id`, or -1. */
static int32_t nogui_tree_find(const nogui_android_tree *tree, int32_t native_id)
{
    if (tree == NULL || native_id <= 0 || tree->order == NULL) {
        return -1;
    }
    size_t low = 0;
    size_t high = tree->len;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        int32_t candidate = (int32_t)tree->nodes[(size_t)tree->order[mid]].native_id;
        if (candidate == native_id) {
            return tree->order[mid];
        }
        if (candidate < native_id) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return -1;
}

static void nogui_tree_free(nogui_android_tree *tree)
{
    if (tree == NULL) {
        return;
    }
    free(tree->order);
    free(tree->member_id);
    free(tree->child_start);
    free(tree->child_ids);
    free(tree->customs);
    free(tree->strings);
    free(tree->nodes);
    free(tree);
}

/*
 * Check an update before anything is copied, so a rejected update leaves the
 * previous tree exactly as it was.
 *
 * A native id has to be positive and addressable as a signed 32-bit value,
 * because that is the whole of what the framework can hold. An id outside that
 * range is refused here rather than truncated, because a truncated id is a
 * different identity and would aim a screen reader at an unrelated control.
 * Zero is the header's absence marker and is never a node. The tree's root and
 * focus must name a node this update publishes, so a tree cannot claim a root
 * its own contents do not contain.
 */
static int32_t nogui_tree_check(const nogui_mobile_tree *update)
{
    if (update->nodes_len == 0) {
        if (update->root != NOGUI_MOBILE_NO_NODE || update->focus != NOGUI_MOBILE_NO_NODE) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        return NOGUI_MOBILE_OK;
    }
    for (size_t i = 0; i < update->nodes_len; ++i) {
        const nogui_mobile_node *node = &update->nodes[i];
        uint64_t id = node->native_id;
        if (id == NOGUI_MOBILE_NO_NODE || id > (uint64_t)INT32_MAX) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        /* A dense index is a position in this update, and index zero is a real
         * position. Absence is the header's own sentinel, which is why it is not
         * zero: a parent of zero must name the first node, not "no parent". */
        if (node->parent != NOGUI_MOBILE_NO_INDEX && node->parent >= update->nodes_len) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        if (node->member_of != NOGUI_MOBILE_NO_INDEX && node->member_of >= update->nodes_len) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        if (node->children_len != 0 && node->children == NULL) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        for (size_t slot = 0; slot < node->children_len; ++slot) {
            if (node->children[slot] >= update->nodes_len) {
                return NOGUI_MOBILE_ERR_ARGUMENT;
            }
        }
        if (node->label_len > NOGUI_MOBILE_MAX_TEXT || node->value_len > NOGUI_MOBILE_MAX_TEXT
            || node->hint_len > NOGUI_MOBILE_MAX_TEXT || node->placeholder_len > NOGUI_MOBILE_MAX_TEXT
            || node->text_len > NOGUI_MOBILE_MAX_TEXT) {
            return NOGUI_MOBILE_ERR_BUFFER;
        }
        for (size_t slot = 0; slot < node->custom_actions_len; ++slot) {
            if (node->custom_actions[slot].name_len > NOGUI_MOBILE_MAX_TEXT) {
                return NOGUI_MOBILE_ERR_BUFFER;
            }
        }
    }
    /* One id per node. Two nodes sharing an id would make every later question
     * about that id answerable two ways. */
    for (size_t i = 0; i < update->nodes_len; ++i) {
        for (size_t j = i + 1; j < update->nodes_len; ++j) {
            if (update->nodes[i].native_id == update->nodes[j].native_id) {
                return NOGUI_MOBILE_ERR_ARGUMENT;
            }
        }
    }
    for (int which = 0; which < 2; ++which) {
        uint64_t relation = which == 0 ? update->root : update->focus;
        if (relation == NOGUI_MOBILE_NO_NODE) {
            continue;
        }
        if (relation > (uint64_t)INT32_MAX) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        bool found = false;
        for (size_t i = 0; i < update->nodes_len && !found; ++i) {
            found = update->nodes[i].native_id == relation;
        }
        if (!found) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
    }
    return NOGUI_MOBILE_OK;
}

/* Build the whole copy. The caller has already checked the update. */
static nogui_android_tree *nogui_tree_build(const nogui_mobile_tree *update)
{
    nogui_android_tree *tree = (nogui_android_tree *)calloc(1, sizeof(*tree));
    if (tree == NULL) {
        return NULL;
    }
    tree->len = update->nodes_len;
    tree->initialized = update->has_tree_init != 0;
    if (update->nodes_len == 0) {
        tree->root = 0;
        tree->focus = 0;
        return tree;
    }

    size_t string_total = 0;
    size_t child_total = 0;
    size_t custom_total = 0;
    for (size_t i = 0; i < update->nodes_len; ++i) {
        const nogui_mobile_node *node = &update->nodes[i];
        string_total += node->label_len + node->value_len + node->hint_len
                      + node->placeholder_len + node->text_len;
        child_total += node->children_len;
        custom_total += node->custom_actions_len;
        for (size_t slot = 0; slot < node->custom_actions_len; ++slot) {
            string_total += node->custom_actions[slot].name_len;
        }
    }

    tree->nodes = (nogui_mobile_node *)calloc(update->nodes_len, sizeof(*tree->nodes));
    tree->child_ids = child_total != 0 ? (int32_t *)calloc(child_total, sizeof(*tree->child_ids)) : NULL;
    tree->child_start = (int32_t *)calloc(update->nodes_len, sizeof(*tree->child_start));
    tree->member_id = (int32_t *)calloc(update->nodes_len, sizeof(*tree->member_id));
    tree->order = (int32_t *)calloc(update->nodes_len, sizeof(*tree->order));
    tree->customs = custom_total != 0
        ? (nogui_mobile_custom_action *)calloc(custom_total, sizeof(*tree->customs)) : NULL;
    tree->strings = string_total != 0 ? (char *)calloc(string_total, 1) : NULL;
    if (tree->nodes == NULL || tree->child_start == NULL || tree->member_id == NULL
        || tree->order == NULL
        || (child_total != 0 && tree->child_ids == NULL)
        || (custom_total != 0 && tree->customs == NULL)
        || (string_total != 0 && tree->strings == NULL)) {
        nogui_tree_free(tree);
        return NULL;
    }

    /* The lookup table is built first, so a child's parent resolves in one
     * search whether it is a list's own child slice or a node that only
     * declared a parent. */
    for (size_t i = 0; i < update->nodes_len; ++i) {
        tree->order[i] = (int32_t)i;
    }
    for (size_t i = 1; i < update->nodes_len; ++i) {
        int32_t key = tree->order[i];
        int64_t key_id = (int64_t)update->nodes[key].native_id;
        size_t hole = i;
        while (hole > 0 && (int64_t)update->nodes[tree->order[hole - 1]].native_id > key_id) {
            tree->order[hole] = tree->order[hole - 1];
            hole -= 1;
        }
        tree->order[hole] = key;
    }

    char *cursor = tree->strings;
    size_t child_at = 0;
    size_t custom_at = 0;
    for (size_t i = 0; i < update->nodes_len; ++i) {
        const nogui_mobile_node *source = &update->nodes[i];
        nogui_mobile_node *node = &tree->nodes[i];
        *node = *source;
        const char *sources[5] = {
            source->label, source->value, source->hint, source->placeholder, source->text,
        };
        size_t lengths[5] = {
            source->label_len, source->value_len, source->hint_len,
            source->placeholder_len, source->text_len,
        };
        /* A node's slice fields are a pointer and a length, so repointing one
         * into this tree's own block is a rewrite of the pointer, not of the
         * bytes. A zero length is null, which is how this ABI says "no string"
         * everywhere. */
        const char **targets[5] = {
            &node->label, &node->value, &node->hint, &node->placeholder, &node->text,
        };
        for (int field = 0; field < 5; ++field) {
            if (lengths[field] == 0 || sources[field] == NULL) {
                *targets[field] = NULL;
                continue;
            }
            memcpy(cursor, sources[field], lengths[field]);
            *targets[field] = cursor;
            cursor += lengths[field];
        }
        /* The dense child list is internal to the shim, so the pointer into the
         * caller's array is dropped rather than left dangling. The count stays,
         * because it is a plain number the framework's own questions need, and
         * the ids themselves are materialised below in the order the core
         * published so a screen reader walks the tree the way the app laid it
         * out. */
        node->children = NULL;
        tree->child_start[i] = (int32_t)child_at;
        for (size_t slot = 0; slot < source->children_len; ++slot) {
            size_t dense = (size_t)source->children[slot];
            tree->child_ids[child_at++] = (int32_t)update->nodes[dense].native_id;
        }
        tree->member_id[i] = source->member_of == NOGUI_MOBILE_NO_INDEX
            ? 0 : (int32_t)update->nodes[(size_t)source->member_of].native_id;
        node->custom_actions = source->custom_actions_len != 0 ? &tree->customs[custom_at] : NULL;
        for (size_t slot = 0; slot < source->custom_actions_len; ++slot) {
            const nogui_mobile_custom_action *from = &source->custom_actions[slot];
            nogui_mobile_custom_action *to = &tree->customs[custom_at];
            to->id = from->id;
            if (from->name == NULL || from->name_len == 0) {
                /* A named action with no name cannot be announced, so it is
                 * never advertised rather than advertised as a blank button. */
                to->name = NULL;
                to->name_len = 0;
            } else {
                memcpy(cursor, from->name, from->name_len);
                to->name = cursor;
                to->name_len = from->name_len;
                cursor += from->name_len;
            }
            custom_at += 1;
        }
    }

    tree->root = update->root == NOGUI_MOBILE_NO_NODE ? 0 : (int32_t)update->root;
    tree->focus = update->focus == NOGUI_MOBILE_NO_NODE ? 0 : (int32_t)update->focus;
    return tree;
}

/* ── E04: the window ─────────────────────────────────────────────────────── */

/* Attach the calling thread to the VM if it is not already in it. */
static JNIEnv *nogui_attach(JavaVM *vm)
{
    if (vm == NULL) {
        return NULL;
    }
    JNIEnv *env = NULL;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_OK) {
        return env;
    }
    if (status != JNI_EDETACHED) {
        return NULL;
    }
    if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK) {
        return NULL;
    }
    return env;
}


/*
 * The discrete facts and the geometry cross in two arrays because a task on
 * another thread has no other way to return a value, and because a measurement
 * squeezed into an integer field would lose the fraction that is the difference
 * between a logical point and a pixel.
 */
#define NOGUI_ANDROID_MEASURE_LONGS 5
#define NOGUI_ANDROID_MEASURE_DOUBLES 8

/*
 * Run a measurement on Android's UI thread and wait, bounded, for the answer.
 *
 * SDL's native main thread is not the UI thread, and the window, its insets and
 * the activity's decor view all belong to the UI thread. The hop is a real
 * `Activity.runOnUiThread` followed by a bounded wait, so the caller's thread is
 * never parked forever on a busy UI thread, and a hop that misses its bound is a
 * refusal the caller can act on rather than a silent wrong answer.
 *
 * A caller already on the UI thread skips the round trip entirely and reads the
 * window in place, which is the case that costs nothing.
 *
 * The result is read back out of two arrays because a task on another thread has
 * no other way to return a value, and an array is the one shape both Java and
 * JNI handle without an object graph. `out_long` carries the discrete facts and
 * `out_double` the geometry, so no measurement is squeezed into a field too
 * small to hold it.
 */

static int32_t nogui_measure(
    JNIEnv *env,
    const struct nogui_android_jni *jni,
    jobject activity,
    jint op,
    jint *out_long,
    double *out_double)
{
    jlongArray longs = (*env)->NewLongArray(env, NOGUI_ANDROID_MEASURE_LONGS);
    jdoubleArray doubles = (*env)->NewDoubleArray(env, NOGUI_ANDROID_MEASURE_DOUBLES);
    if ((*env)->ExceptionCheck(env) || longs == NULL || doubles == NULL) {
        nogui_clear_exception(env);
        if (longs != NULL) {
            (*env)->DeleteLocalRef(env, longs);
        }
        if (doubles != NULL) {
            (*env)->DeleteLocalRef(env, doubles);
        }
        return NOGUI_MOBILE_ERR_MEMORY;
    }
    jint status = (*env)->CallStaticIntMethod(
        env, jni->provider_class, jni->provider_measure, activity, op, longs, doubles);
    nogui_clear_exception(env);
    if (status != NOGUI_MOBILE_OK) {
        /* A refusal that happened on the UI thread is reported unchanged, so a
         * platform that cannot answer is distinguishable from a hop that timed
         * out on a busy thread. */
        (*env)->DeleteLocalRef(env, longs);
        (*env)->DeleteLocalRef(env, doubles);
        return status;
    }
    jlong read_long[NOGUI_ANDROID_MEASURE_LONGS];
    jdouble read_double[NOGUI_ANDROID_MEASURE_DOUBLES];
    (*env)->GetLongArrayRegion(env, longs, 0, NOGUI_ANDROID_MEASURE_LONGS, read_long);
    (*env)->GetDoubleArrayRegion(env, doubles, 0, NOGUI_ANDROID_MEASURE_DOUBLES, read_double);
    nogui_clear_exception(env);
    for (jint slot = 0; slot < NOGUI_ANDROID_MEASURE_LONGS; ++slot) {
        out_long[slot] = (jint)read_long[slot];
    }
    for (jint slot = 0; slot < NOGUI_ANDROID_MEASURE_DOUBLES; ++slot) {
        out_double[slot] = (double)read_double[slot];
    }
    (*env)->DeleteLocalRef(env, longs);
    (*env)->DeleteLocalRef(env, doubles);
    return NOGUI_MOBILE_OK;
}
/* The window's decor view, the root every measurement is taken against. */
static jobject nogui_decor_view(JNIEnv *env, const struct nogui_android_jni *jni, jobject activity)
{
    jmethodID get_window = nogui_method(env, jni->activity_class, "getWindow", "()Landroid/view/Window;");
    if (get_window == NULL) {
        return NULL;
    }
    jobject window = (*env)->CallObjectMethod(env, activity, get_window);
    if ((*env)->ExceptionCheck(env) || window == NULL) {
        nogui_clear_exception(env);
        return NULL;
    }
    jobject decor = (*env)->CallObjectMethod(env, window, jni->window_get_decor);
    (*env)->DeleteLocalRef(env, window);
    if ((*env)->ExceptionCheck(env) || decor == NULL) {
        nogui_clear_exception(env);
        return NULL;
    }
    return decor;
}


/* ── E04: insets and the soft keyboard ────────────────────────────────────── */

/*
 * What one pass over the window found.
 *
 * The insets and the keyboard are read together on purpose. They are two
 * questions about the same `WindowInsets` object, and answering them in one
 * place is what stops a layout from trusting a system-bar measurement while the
 * keyboard is on screen: `systemBars` does not move when the input method does,
 * so a layout that trusted it alone would sit under the keyboard.
 */
typedef struct nogui_android_window {
    int32_t insets_measured;
    nogui_mobile_insets insets;
    /* Whether the platform answered the input-method question at all. On an API
     * level that does not model it this stays 0, and every keyboard field below
     * is then unknown rather than a fabricated "no keyboard". */
    int32_t keyboard_answered;
    int32_t keyboard_supported;
    int32_t keyboard_visible;
    int32_t frame_measured;
    nogui_mobile_rect frame;
} nogui_android_window;

/* Read the four edges of a `Rect`, or leave them absent. */
static int32_t nogui_rect_edges(JNIEnv *env, jobject rect, jint *out)
{
    jclass rect_class = (*env)->GetObjectClass(env, rect);
    if (rect_class == NULL) {
        nogui_clear_exception(env);
        return NOGUI_MOBILE_ERR_FAULT;
    }
    jfieldID left = nogui_field(env, rect_class, "left", "I");
    jfieldID top = nogui_field(env, rect_class, "top", "I");
    jfieldID right = nogui_field(env, rect_class, "right", "I");
    jfieldID bottom = nogui_field(env, rect_class, "bottom", "I");
    int32_t status = NOGUI_MOBILE_OK;
    if (left == NULL || top == NULL || right == NULL || bottom == NULL) {
        status = NOGUI_MOBILE_ERR_UNAVAILABLE;
    } else {
        out[0] = (*env)->GetIntField(env, rect, left);
        out[1] = (*env)->GetIntField(env, rect, top);
        out[2] = (*env)->GetIntField(env, rect, right);
        out[3] = (*env)->GetIntField(env, rect, bottom);
    }
    (*env)->DeleteLocalRef(env, rect_class);
    return status;
}

static int32_t nogui_read_window(
    JNIEnv *env,
    const struct nogui_android_jni *jni,
    jobject activity,
    nogui_android_window *out)
{
    memset(out, 0, sizeof(*out));
    if (jni->view_get_width == NULL || jni->view_get_height == NULL
        || jni->view_get_root_insets == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    jobject decor = nogui_decor_view(env, jni, activity);
    if (decor == NULL) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    jint w = (*env)->CallIntMethod(env, decor, jni->view_get_width);
    jint h = (*env)->CallIntMethod(env, decor, jni->view_get_height);
    nogui_clear_exception(env);
    if (w <= 0 || h <= 0) {
        /* A window with no size has no insets to state, and reporting zero on
         * every edge here would be a real reading of nothing. */
        (*env)->DeleteLocalRef(env, decor);
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    jobject insets = (*env)->CallObjectMethod(env, decor, jni->view_get_root_insets);
    if ((*env)->ExceptionCheck(env)) {
        nogui_clear_exception(env);
        insets = NULL;
    }
    int32_t status = NOGUI_MOBILE_ERR_UNAVAILABLE;

    if (insets != NULL) {
        if (jni->insets_get_insets != NULL && jni->type_ime != NULL && jni->type_status_bars != NULL) {
            jint safe = jni->type_status_bars | jni->type_navigation_bars
                      | jni->type_caption_bar | jni->type_display_cutout;
            jint ime = (*env)->GetStaticIntField(env, jni->insets_type_class, jni->type_ime);
            if (safe != 0) {
                jobject rect = (*env)->CallObjectMethod(env, insets, jni->insets_get_insets, safe);
                if ((*env)->ExceptionCheck(env)) {
                    nogui_clear_exception(env);
                } else if (rect != NULL) {
                    jint edges[4];
                    if (nogui_rect_edges(env, rect, edges) == NOGUI_MOBILE_OK) {
                        /* `getInsets` states absolute edges against the window
                         * and this ABI states insets inward from it, so a caller
                         * can mix the two platforms without knowing which one
                         * produced the numbers. */
                        out->insets.left = (double)(edges[0] > 0 ? edges[0] : 0);
                        out->insets.top = (double)(edges[1] > 0 ? edges[1] : 0);
                        out->insets.right = (double)(w > edges[2] ? w - edges[2] : 0);
                        out->insets.bottom = (double)(h > edges[3] ? h - edges[3] : 0);
                        out->insets_measured = 1;
                    }
                    (*env)->DeleteLocalRef(env, rect);
                }
            }
            if (jni->insets_is_visible != NULL) {
                out->keyboard_supported = 1;
                jboolean visible = (*env)->CallBooleanMethod(env, insets, jni->insets_is_visible, ime);
                if ((*env)->ExceptionCheck(env)) {
                    /* The framework raised on the question, which is an answer
                     * of "I cannot say" rather than of "not visible". Saying it
                     * is not visible would be a fabricated hidden keyboard. */
                    nogui_clear_exception(env);
                    out->keyboard_answered = 0;
                    out->keyboard_supported = 0;
                } else {
                    out->keyboard_answered = 1;
                    out->keyboard_visible = visible == JNI_TRUE ? 1 : 0;
                }
            }
            if (out->keyboard_visible && jni->insets_get_insets != NULL) {
                jobject rect = (*env)->CallObjectMethod(env, insets, jni->insets_get_insets, ime);
                if ((*env)->ExceptionCheck(env)) {
                    nogui_clear_exception(env);
                } else if (rect != NULL) {
                    jint edges[4];
                    if (nogui_rect_edges(env, rect, edges) == NOGUI_MOBILE_OK) {
                        /* The input-method inset is a real rectangle in window
                         * pixels: the keyboard covers the width of the window
                         * from its own top edge down to the bottom. It is
                         * reported as that rectangle rather than as a bottom
                         * inset, because a caller that lays out around a
                         * keyboard needs to know where its top edge is. */
                        out->frame.x0 = (double)edges[0];
                        out->frame.y0 = (double)edges[1];
                        out->frame.x1 = (double)edges[2];
                        out->frame.y1 = (double)edges[3];
                        out->frame_measured = 1;
                    }
                    (*env)->DeleteLocalRef(env, rect);
                }
            }
            status = out->insets_measured ? NOGUI_MOBILE_OK : NOGUI_MOBILE_ERR_UNAVAILABLE;
        } else if (jni->view_get_inset_top != NULL && jni->view_get_inset_left != NULL
                   && jni->view_get_inset_bottom != NULL && jni->view_get_inset_right != NULL) {
            /* Before API 30 the framework still states the system bars, as the
             * stable insets on the view. That is a complete answer to the
             * safe-area question, so it is reported as one, and the keyboard
             * question stays unanswered because nothing on this API level can
             * answer it. */
            jint t = (*env)->CallIntMethod(env, decor, jni->view_get_inset_top);
            jint l = (*env)->CallIntMethod(env, decor, jni->view_get_inset_left);
            jint b = (*env)->CallIntMethod(env, decor, jni->view_get_inset_bottom);
            jint r = (*env)->CallIntMethod(env, decor, jni->view_get_inset_right);
            nogui_clear_exception(env);
            out->insets.top = (double)(t > 0 ? t : 0);
            out->insets.left = (double)(l > 0 ? l : 0);
            out->insets.bottom = (double)(b > 0 ? b : 0);
            out->insets.right = (double)(r > 0 ? r : 0);
            out->insets_measured = 1;
            status = NOGUI_MOBILE_OK;
        }
    }
    if (insets != NULL) {
        (*env)->DeleteLocalRef(env, insets);
    }
    (*env)->DeleteLocalRef(env, decor);
    /* No scale is applied here. The framework measured this window in physical
     * pixels and this ABI asks for physical pixels, so the numbers cross
     * unchanged. Converting by display density would be wrong twice over: the
     * unit is already right, and density is not the scale SDL renders at. */
    return status;
}

/* The measurements the C half asks the UI thread to take. The values are a
 * contract with NoguiAccessibilityProvider.java and are named on both sides. */
#define NOGUI_ANDROID_OP_INSETS 1
#define NOGUI_ANDROID_OP_KEYBOARD 2
/* Not a measurement: the one operation on this hop that is an effect. The
 * framework's own answer crosses back in the same arrays. */
#define NOGUI_ANDROID_OP_DEFER_BACK 3

/*
 * The measurement the UI thread performed, read back out of the arrays the hop
 * filled. Both entry points below want the same reading, and taking it from one
 * place is what keeps the safe area and the keyboard from being two different
 * measurements of one window.
 */
static void nogui_window_from_arrays(
    const jint *facts,
    const double *geometry,
    nogui_android_window *out)
{
    memset(out, 0, sizeof(*out));
    out->insets_measured = facts[0];
    out->insets.left = geometry[0];
    out->insets.top = geometry[1];
    out->insets.right = geometry[2];
    out->insets.bottom = geometry[3];
    out->keyboard_answered = facts[1];
    out->keyboard_supported = facts[2];
    out->keyboard_visible = facts[3];
    out->frame_measured = facts[4];
    out->frame.x0 = geometry[4];
    out->frame.y0 = geometry[5];
    out->frame.x1 = geometry[6];
    out->frame.y1 = geometry[7];
}

/*
 * Safe-area insets, in logical points.
 *
 * The system bars and the display cutout are the covered edges of this window.
 * The input method is not part of a safe area: it is a transient thing that
 * appears over the app's own content, and folding it in here would make this
 * answer mean something different from the iOS one, which is the whole reason
 * both platforms state insets in the same unit and the same direction. A caller
 * that wants the keyboard asks for it, and gets a separate answer with its own
 * frame.
 */
int32_t nogui_android_window_insets(void *env_handle, void *activity_handle, nogui_mobile_insets *out)
{
    if (env_handle == NULL || activity_handle == NULL || out == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    memset(out, 0, sizeof(*out));
    JNIEnv *env = (JNIEnv *)env_handle;
    jobject activity = (jobject)activity_handle;

    struct nogui_android_jni jni;
    memset(&jni, 0, sizeof(jni));
    int32_t status = nogui_resolve_window(env, &jni);
    jint facts[NOGUI_ANDROID_MEASURE_LONGS];
    double geometry[NOGUI_ANDROID_MEASURE_DOUBLES];
    memset(facts, 0, sizeof(facts));
    memset(geometry, 0, sizeof(geometry));
    if (status == NOGUI_MOBILE_OK) {
        status = nogui_measure(env, &jni, activity, NOGUI_ANDROID_OP_INSETS, facts, geometry);
    }
    nogui_release_jni(env, &jni);
    if (status != NOGUI_MOBILE_OK) {
        return status;
    }
    if (facts[0] == 0) {
        /* Zero on every edge is a real reading on a device with no cutout and no
         * system bar, so it is only ever published beside a status that says the
         * measurement happened. Without one, the honest answer is that the
         * platform could not measure. */
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    out->left = geometry[0];
    out->top = geometry[1];
    out->right = geometry[2];
    out->bottom = geometry[3];
    return NOGUI_MOBILE_OK;
}

/*
 * The soft keyboard, as the window states it.
 *
 * `WindowInsets.isVisible(Type.ime())` is the platform's own answer to whether
 * the input method is on screen. `InputMethodManager.isAcceptingText()` is not:
 * it answers whether an input method would accept a character right now, which
 * is true of a hardware keyboard and of a text field that is not being edited,
 * so a layout that trusted it would reserve space for a keyboard that is not
 * there and would not reserve space for one that is.
 *
 * Visibility and geometry are two questions and are answered separately. On an
 * API level that models the input method, visibility is a real reading and the
 * frame is the real rectangle the input method occupies. Below that, no public
 * API can answer either, so `status` is NOGUI_MOBILE_ERR_UNAVAILABLE and
 * `supported` and `visible` stay 0: unknown, not "no keyboard". The header says
 * a field is meaningful only when `status` is NOGUI_MOBILE_OK, and that is what
 * makes those zeros a refusal rather than a claim.
 */
int32_t nogui_android_window_keyboard(void *env_handle, void *activity_handle, nogui_mobile_keyboard *out)
{
    if (env_handle == NULL || activity_handle == NULL || out == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    memset(out, 0, sizeof(*out));
    JNIEnv *env = (JNIEnv *)env_handle;
    jobject activity = (jobject)activity_handle;

    struct nogui_android_jni jni;
    memset(&jni, 0, sizeof(jni));
    int32_t status = nogui_resolve_window(env, &jni);
    jint facts[NOGUI_ANDROID_MEASURE_LONGS];
    double geometry[NOGUI_ANDROID_MEASURE_DOUBLES];
    memset(facts, 0, sizeof(facts));
    memset(geometry, 0, sizeof(geometry));
    if (status == NOGUI_MOBILE_OK) {
        status = nogui_measure(env, &jni, activity, NOGUI_ANDROID_OP_KEYBOARD, facts, geometry);
    }
    nogui_release_jni(env, &jni);
    if (status != NOGUI_MOBILE_OK) {
        out->status = status;
        return status;
    }
    nogui_android_window reading;
    nogui_window_from_arrays(facts, geometry, &reading);
    if (!reading.keyboard_answered) {
        /* Nothing on this API level can say whether the input method is on
         * screen. That is not the same as saying it is not, so the status says
         * so and the fields stay absent. */
        out->status = NOGUI_MOBILE_ERR_UNAVAILABLE;
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    out->supported = reading.keyboard_supported;
    out->visible = reading.keyboard_visible;
    if (reading.keyboard_visible && reading.frame_measured) {
        out->frame = reading.frame;
    }
    out->status = NOGUI_MOBILE_OK;
    return NOGUI_MOBILE_OK;
}

/* Giving a back request back to the platform, on Android's UI thread.
 *
 * The application's policy decides whether a back request was consumed; this is
 * what a decision to defer turns into. The key event cannot be handed back —
 * the pump that observed it already removed it from SDL's queue, so a deferral
 * that took no platform action left the key travelling on as an ordinary key
 * press the model would act on. `moveTaskToBack` is the framework's own
 * behaviour for a back press nothing consumed, and its answer is reported: a
 * framework that declines to move the task is told so rather than being
 * recorded as a deferral that happened.
 */
int32_t nogui_android_defer_back(void *env_handle, void *activity_handle)
{
    if (env_handle == NULL || activity_handle == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    JNIEnv *env = (JNIEnv *)env_handle;
    jobject activity = (jobject)activity_handle;

    struct nogui_android_jni jni;
    memset(&jni, 0, sizeof(jni));
    int32_t status = nogui_resolve_window(env, &jni);
    jint facts[NOGUI_ANDROID_MEASURE_LONGS];
    double geometry[NOGUI_ANDROID_MEASURE_DOUBLES];
    memset(facts, 0, sizeof(facts));
    memset(geometry, 0, sizeof(geometry));
    if (status == NOGUI_MOBILE_OK) {
        status = nogui_measure(env, &jni, activity, NOGUI_ANDROID_OP_DEFER_BACK, facts, geometry);
    }
    nogui_release_jni(env, &jni);
    if (status == NOGUI_MOBILE_OK && facts[0] == 0) {
        return NOGUI_MOBILE_ERR_REFUSED;
    }
    return status;
}

/* ── E04: memory pressure ─────────────────────────────────────────────────── */

/*
 * `onTrimMemory` is delivered to the Java activity, which forwards the platform
 * level through `dispatchTrimMemory`. The mapping is here so the level this
 * bridge publishes and the level Android states are converted in one place.
 *
 * `TRIM_MEMORY_UI_HIDDEN` and `TRIM_MEMORY_BACKGROUND` are lifecycle facts — the
 * app's views are not visible — and not evidence that memory is short, so they
 * map to NONE deliberately. Reading them as pressure would make a backgrounded
 * app release caches it needs the moment it is resumed, which is the opposite of
 * what the platform asked for.
 */
static _Atomic int32_t nogui_android_trim = NOGUI_MOBILE_ANDROID_TRIM_NONE;

int32_t nogui_android_memory_pressure(void)
{
    return atomic_load(&nogui_android_trim);
}

static void nogui_android_record_trim(jint level)
{
    int32_t mapped;
    switch (level) {
    case 10: /* TRIM_MEMORY_RUNNING_LOW */
        mapped = NOGUI_MOBILE_ANDROID_TRIM_RUNNING_LOW;
        break;
    case 15: /* TRIM_MEMORY_RUNNING_CRITICAL */
        mapped = NOGUI_MOBILE_ANDROID_TRIM_RUNNING_CRITICAL;
        break;
    case 60: /* TRIM_MEMORY_MODERATE */
    case 80: /* TRIM_MEMORY_COMPLETE */
        /* MODERATE already means the process is a candidate for death, and the
         * header's scale stops at COMPLETE, so both land on its top step
         * rather than inventing an intermediate one. */
        mapped = NOGUI_MOBILE_ANDROID_TRIM_COMPLETE;
        break;
    default:
        /* 5 RUNNING_MODERATE, 20 UI_HIDDEN, 40 BACKGROUND and anything this
         * platform adds later are not pressure this bridge can act on. */
        mapped = NOGUI_MOBILE_ANDROID_TRIM_NONE;
        break;
    }
    atomic_store(&nogui_android_trim, mapped);
}

/* ── E05: lifecycle ───────────────────────────────────────────────────────── */

nogui_mobile_bridge *nogui_android_a11y_new(
    void *user,
    nogui_mobile_action_fn on_action,
    nogui_mobile_dirty_fn on_dirty)
{
    if (on_action == NULL) {
        return NULL;
    }
    nogui_mobile_bridge *bridge = (nogui_mobile_bridge *)calloc(1, sizeof(*bridge));
    if (bridge == NULL) {
        return NULL;
    }
    bridge->user = user;
    bridge->on_action = on_action;
    bridge->on_dirty = on_dirty;
    bridge->slot = -1;
    if (nogui_android_publish(bridge) != NOGUI_MOBILE_OK) {
        free(bridge);
        return NULL;
    }
    return bridge;
}

/*
 * Drop everything a bridge holds.
 *
 * The provider is taken off the decor view through a posted hop, because that
 * is a view mutation and the caller is SDL's native thread rather than Android's
 * UI thread. The hop is not waited on: the work it does touches only Java
 * objects, so it is still correct if it lands after this returns and the C
 * storage is gone, and a teardown that could block on a busy UI thread is a
 * teardown that can hang the host at the one moment it must not.
 *
 * The references themselves are dropped here, on whichever thread the teardown
 * runs, because releasing a global reference is not a view operation. The
 * bridge was taken out of the table of live ones and drained of in-flight calls
 * before this runs, so nothing can be using them.
 */
static void nogui_android_a11y_teardown(nogui_mobile_bridge *bridge, JNIEnv *env)
{
    if (env != NULL) {
        if (bridge->provider != NULL && bridge->host_view != NULL
                && bridge->jni.provider_uninstall != NULL && bridge->activity != NULL) {
            (*env)->CallStaticVoidMethod(
                env, bridge->jni.provider_class, bridge->jni.provider_uninstall,
                bridge->activity, bridge->host_view);
            nogui_clear_exception(env);
        }
        if (bridge->provider != NULL) {
            (*env)->DeleteGlobalRef(env, bridge->provider);
        }
        if (bridge->host_view != NULL) {
            (*env)->DeleteGlobalRef(env, bridge->host_view);
        }
        if (bridge->package_name != NULL) {
            (*env)->DeleteGlobalRef(env, bridge->package_name);
        }
        if (bridge->activity != NULL) {
            (*env)->DeleteGlobalRef(env, bridge->activity);
        }
        nogui_release_jni(env, &bridge->jni);
    }
    bridge->provider = NULL;
    bridge->host_view = NULL;
    bridge->package_name = NULL;
    bridge->activity = NULL;
    bridge->origin_x = 0;
    bridge->origin_y = 0;
    bridge->attached = 0;
}

/*
 * Take the bridge out of the table of live ones, then wait for the framework
 * calls already inside it.
 *
 * The wait is what makes a free safe. A provider outlives the frame that made
 * it, and the framework can be mid-call on another thread at the moment the host
 * tears the bridge down; without the wait that call would return into freed
 * storage. Removing the entry first means no new call can find the bridge at
 * all, so the wait is bounded by the calls that were already inside.
 */
static void nogui_android_a11y_unpublish(nogui_mobile_bridge *bridge)
{
    nogui_lock_acquire();
    int32_t slot = bridge->slot;
    if (slot >= 0 && slot < NOGUI_ANDROID_SLOTS && nogui_android_slots[slot] == bridge) {
        nogui_android_slots[slot] = NULL;
        bridge->dead = 1;
        while (nogui_android_slot_refs[slot] > 0) {
            pthread_cond_wait(&nogui_drained, &nogui_lock);
        }
    }
    nogui_lock_release();
}

void nogui_android_a11y_free(nogui_mobile_bridge *bridge)
{
    if (bridge == NULL) {
        return;
    }
    nogui_android_a11y_unpublish(bridge);
    JNIEnv *env = nogui_attach(bridge->vm);
    nogui_android_a11y_teardown(bridge, env);
    nogui_tree_free(bridge->tree);
    bridge->tree = NULL;
    free(bridge);
}

void nogui_android_a11y_detach(nogui_mobile_bridge *bridge)
{
    if (bridge == NULL) {
        return;
    }
    /* A detach is not a free: the bridge stays published, so a re-attach finds
     * the same object. It is emptied of everything the framework can reach, and
     * the tree is released only once no call is inside the bridge, which is what
     * makes a call in flight during the teardown produce no node rather than a
     * node from a half-released tree. */
    nogui_android_a11y_unpublish(bridge);
    JNIEnv *env = nogui_attach(bridge->vm);
    nogui_android_a11y_teardown(bridge, env);
    nogui_tree_free(bridge->tree);
    bridge->tree = NULL;
    bridge->window_focused = 0;
    nogui_lock_acquire();
    /* Published again, empty: a re-attach starts from nothing, and a call that
     * arrives in between finds a live bridge with no tree and answers "no
     * node", which is true. */
    bridge->dead = 0;
    if (bridge->slot >= 0 && bridge->slot < NOGUI_ANDROID_SLOTS
            && nogui_android_slots[bridge->slot] == NULL) {
        nogui_android_slots[bridge->slot] = bridge;
    }
    nogui_lock_release();
}

/*
 * Attach the bridge to a window.
 *
 * The provider is created here rather than left to the framework, because a
 * provider is not something the framework instantiates: it is something a view
 * hands back, and the view here is the one SDL renders into. The delegate
 * installed on it is the supported way to do that without replacing a view
 * class or adding a view to the hierarchy.
 *
 * SDL hands the activity out as a LOCAL reference that dies with the native
 * frame it arrived in, and it releases it once its poll and attach are done. So
 * this promotes it to a global reference for the life of the attachment, keeps
 * the VM rather than the `JNIEnv`, and never stores an environment across
 * threads: a `JNIEnv` belongs to the thread that got it and is meaningless on
 * another. Anything this file needs on a thread of its own, it obtains there
 * through `nogui_attach`.
 */

/*
 * Release one local reference the caller owns.
 *
 * SDL hands out a local reference to its activity and expects the caller to
 * release it. Doing that from Zig means naming `DeleteLocalRef`, which is a JNI
 * detail this ABI otherwise hides; this is that detail, with the two rules
 * around it kept in one place. A pending exception makes every other JNI call
 * unsafe, so it is cleared first. A null object is what "nothing was
 * acquired" looks like, and releasing it is a no-op rather than a fault.
 */
void nogui_android_release_local(void *env_handle, void *object_handle)
{
    if (env_handle == NULL || object_handle == NULL) {
        return;
    }
    JNIEnv *env = (JNIEnv *)env_handle;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, (jobject)object_handle);
}

int32_t nogui_android_a11y_attach(nogui_mobile_bridge *bridge, void *env_handle, void *activity_handle)
{
    if (bridge == NULL || env_handle == NULL || activity_handle == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    JNIEnv *env = (JNIEnv *)env_handle;
    jobject activity = (jobject)activity_handle;
    /* Detach drains callbacks before releasing the old JNI globals/delegate. */
    if (bridge->attached) {
        nogui_android_a11y_detach(bridge);
    }
    int32_t status = nogui_resolve_bridge(env, &bridge->jni);
    if (status != NOGUI_MOBILE_OK) {
        nogui_release_jni(env, &bridge->jni);
        return status;
    }
    /* The provider object is ordinary JNI work and needs no particular thread,
     * so it is created here and the posted hop is left with nothing but the view
     * mutation, which is the part that must happen on the UI thread. */
    jobject provider = (*env)->NewObject(env, bridge->jni.provider_class, bridge->jni.provider_ctor);
    if ((*env)->ExceptionCheck(env) || provider == NULL) {
        nogui_clear_exception(env);
        nogui_release_jni(env, &bridge->jni);
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    bridge->activity = (*env)->NewGlobalRef(env, activity);
    bridge->provider = (*env)->NewGlobalRef(env, provider);
    jclass activity_class = (*env)->GetObjectClass(env, activity);
    jmethodID get_package = nogui_method(env, activity_class, "getPackageName", "()Ljava/lang/String;");
    jstring package = get_package != NULL ? (jstring)(*env)->CallObjectMethod(env, activity, get_package) : NULL;
    nogui_clear_exception(env);
    (*env)->DeleteLocalRef(env, activity_class);
    /* The app's real package name, kept for the life of the attachment because
     * `setPackageName` is what a screen reader groups a node by, and a node
     * announced as another app's would be a claim this shim cannot make. */
    bridge->package_name = package != NULL ? (jstring)(*env)->NewGlobalRef(env, package) : NULL;
    if (package != NULL) {
        (*env)->DeleteLocalRef(env, package);
    }
    (*env)->DeleteLocalRef(env, provider);
    if (bridge->activity == NULL || bridge->provider == NULL) {
        nogui_android_a11y_teardown(bridge, env);
        return NOGUI_MOBILE_ERR_MEMORY;
    }
    (void)(*env)->GetJavaVM(env, &bridge->vm);

    /* The install reaches the UI thread as a bounded hop. The provider holds no
     * bridge handle until the posted runnable runs, so a framework call cannot
     * arrive on a bridge that is still being attached. */
    (*env)->CallStaticVoidMethod(
        env, bridge->jni.provider_class, bridge->jni.provider_stage, bridge->provider);
    nogui_clear_exception(env);
    jint installed = (*env)->CallStaticIntMethod(
        env, bridge->jni.provider_class, bridge->jni.provider_install,
        activity, (jlong)(intptr_t)bridge);
    nogui_clear_exception(env);
    if (installed != NOGUI_MOBILE_OK) {
        /* Nothing is installed, so nothing needs uninstalling. The refusal is
         * the hop's own: a busy UI thread and a platform that cannot host a
         * provider are told apart by their codes. */
        nogui_android_a11y_teardown(bridge, env);
        return installed;
    }
    /* The view the install landed on, and where it sits on screen. The Java side
     * answers both rather than the C side, because only the UI thread may walk a
     * view hierarchy or ask a view where it is. `getLocationOnScreen` is public
     * API, so the origin is measured rather than assumed to be the decor view's
     * — which it is not, on any window with a status bar or a cutout. */
    jobject host = (*env)->CallStaticObjectMethod(
        env, bridge->jni.provider_class, bridge->jni.provider_installed_host);
    nogui_clear_exception(env);
    if ((*env)->ExceptionCheck(env) || host == NULL) {
        nogui_clear_exception(env);
        nogui_android_a11y_teardown(bridge, env);
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    bridge->host_view = (*env)->NewGlobalRef(env, host);
    (*env)->DeleteLocalRef(env, host);
    if (bridge->host_view == NULL) {
        nogui_android_a11y_teardown(bridge, env);
        return NOGUI_MOBILE_ERR_MEMORY;
    }
    jintArray origin = (*env)->CallStaticObjectMethod(
        env, bridge->jni.provider_class, bridge->jni.provider_host_origin);
    nogui_clear_exception(env);
    if ((*env)->ExceptionCheck(env) || origin == NULL) {
        nogui_clear_exception(env);
        nogui_android_a11y_teardown(bridge, env);
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    jint point[2] = { 0, 0 };
    (*env)->GetIntArrayRegion(env, origin, 0, 2, point);
    (*env)->DeleteLocalRef(env, origin);
    nogui_clear_exception(env);
    bridge->origin_x = point[0];
    bridge->origin_y = point[1];

    /* A re-attached bridge has no live tree, so the next update has to
     * re-declare the whole thing rather than patch a tree the framework no
     * longer holds. */
    nogui_lock_acquire();
    nogui_tree_free(bridge->tree);
    bridge->tree = NULL;
    bridge->window_focused = 0;
    bridge->attached = 1;
    nogui_lock_release();
    return NOGUI_MOBILE_OK;
}

int32_t nogui_android_a11y_is_active(const nogui_mobile_bridge *bridge)
{
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    int32_t active = bridge->attached && !bridge->dead && bridge->tree != NULL
                  && bridge->tree->root != 0;
    nogui_lock_release();
    return active ? 1 : 0;
}

int32_t nogui_android_a11y_set_window_focused(nogui_mobile_bridge *bridge, int32_t focused)
{
    if (bridge == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    nogui_lock_acquire();
    bridge->window_focused = focused != 0;
    nogui_lock_release();
    return NOGUI_MOBILE_OK;
}

/*
 * Tell the framework this window's content changed.
 *
 * A window that does not hear this keeps announcing the previous tree, which is
 * the difference between a screen reader that follows the app and one that
 * describes a screen the app has left. The event is the platform's own
 * TYPE_WINDOW_CONTENT_CHANGED, sent from the host view, and its id is read from
 * the framework at attach rather than written here so a platform that lacks it
 * produces a refusal instead of a made-up event.
 */
int32_t nogui_android_a11y_layout_changed(nogui_mobile_bridge *bridge)
{
    if (bridge == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    nogui_lock_acquire();
    JNIEnv *env = nogui_attach(bridge->vm);
    int32_t status = NOGUI_MOBILE_ERR_UNAVAILABLE;
    if (env != NULL && bridge->attached && bridge->host_view != NULL
            && bridge->activity != NULL && bridge->jni.provider_content_changed != NULL
            && bridge->jni.event_content_changed != 0) {
        /* Sending the event is a view operation, so it goes through the same
         * posted hop the install uses. The hop is not waited on: a content
         * change that lands after the caller has moved on is still correct, and
         * a layout call is made often enough that blocking it on a busy UI
         * thread would cost more than it is worth. */
        (*env)->CallStaticVoidMethod(
            env, bridge->jni.provider_class, bridge->jni.provider_content_changed,
            bridge->activity, bridge->host_view, bridge->jni.event_content_changed);
        nogui_clear_exception(env);
        status = NOGUI_MOBILE_OK;
    }
    nogui_lock_release();
    return status;
}

/* ── E05: publishing a tree ───────────────────────────────────────────────── */

int32_t nogui_android_a11y_update(nogui_mobile_bridge *bridge, const nogui_mobile_tree *update)
{
    if (bridge == NULL || update == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    nogui_lock_acquire();
    int32_t attached = bridge->attached;
    nogui_lock_release();
    if (!attached) {
        return NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    int32_t checked = nogui_tree_check(update);
    if (checked != NOGUI_MOBILE_OK) {
        return checked;
    }
    /* The whole new tree is built before anything is swapped, so a publish that
     * cannot be afforded leaves the previous tree serving the framework rather
     * than leaving it with half of one. */
    nogui_android_tree *tree = nogui_tree_build(update);
    if (tree == NULL) {
        return NOGUI_MOBILE_ERR_MEMORY;
    }
    nogui_lock_acquire();
    nogui_android_tree *previous = bridge->tree;
    bridge->tree = tree;
    nogui_lock_release();
    nogui_tree_free(previous);
    /* A publish that landed is a wake, and the host is told so. This is the
     * same signal iOS raises after a successful publish and it means the same
     * thing there: what the platform holds has moved, so the window driver
     * should look at it again. It is a redraw request, not a request to publish
     * — the host answers a dirty flag by reading, and a publish that made no
     * change publishes nothing on the next pump. Leaving it unfired made the
     * identical Zig call site wake on iOS and never on Android. */
    nogui_lock_acquire();
    nogui_mobile_dirty_fn on_dirty = bridge->on_dirty;
    void *user = bridge->user;
    nogui_lock_release();
    if (on_dirty != NULL) {
        on_dirty(user);
    }
    return NOGUI_MOBILE_OK;
}

/* ── E05: text positions ──────────────────────────────────────────────────── */

/*
 * The core counts a character per entry of its character table, and that table
 * is the UTF-8 byte length of one code point: a supplementary character is one
 * character with four bytes, not two characters with three. Android states a
 * position in UTF-16 code units, where that same character is two units. So a
 * position crossing this boundary has to be converted against the run's own
 * text, and counting code units as characters would put the caret inside an
 * emoji and edit the model at an offset that is not a character boundary.
 *
 * Both directions walk the published text. An offset that lands inside a
 * surrogate pair, or past the end of the run, has no character position and is
 * refused: snapping it to the nearest boundary would move the caret somewhere
 * the user did not ask for.
 */
static int32_t nogui_char_of_utf16(const char *text, size_t len, int32_t utf16, int64_t *out)
{
    size_t at = 0;
    int32_t units = 0;
    int64_t characters = 0;
    while (units < utf16) {
        if (at >= len) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        uint32_t cp = 0;
        size_t step = nogui_utf8_step(text, len, at, &cp);
        if (step == 0) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        int32_t width = cp >= 0x10000u ? 2 : 1;
        if (units + width > utf16) {
            /* The offset falls between the two halves of a surrogate pair,
             * which is not a position any character starts at. */
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        units += width;
        characters += 1;
        at += step;
    }
    *out = characters;
    return NOGUI_MOBILE_OK;
}

static int32_t nogui_utf16_of_char(const char *text, size_t len, int64_t characters, int32_t *out)
{
    if (characters < 0) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    size_t at = 0;
    int32_t units = 0;
    int64_t seen = 0;
    while (seen < characters) {
        if (at >= len) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        uint32_t cp = 0;
        size_t step = nogui_utf8_step(text, len, at, &cp);
        if (step == 0) {
            return NOGUI_MOBILE_ERR_ARGUMENT;
        }
        units += cp >= 0x10000u ? 2 : 1;
        seen += 1;
        at += step;
    }
    *out = units;
    return NOGUI_MOBILE_OK;
}

/* ── E05: building a real AccessibilityNodeInfo ───────────────────────────── */

/*
 * `className` is the platform's role carrier: TalkBack announces it, and a node
 * with none is announced as an unlabelled generic. The names below are the
 * framework's own widget classes, so the core's neutral role is translated into
 * the vocabulary a screen reader already has a phrase for rather than into a
 * private taxonomy it has no word for.
 */
static const char *nogui_class_name(uint8_t role)
{
    switch (role) {
    case NOGUI_MOBILE_ROLE_BUTTON:
        return "android.widget.Button";
    case NOGUI_MOBILE_ROLE_CHECK_BOX:
        return "android.widget.CheckBox";
    case NOGUI_MOBILE_ROLE_RADIO_BUTTON:
        return "android.widget.RadioButton";
    case NOGUI_MOBILE_ROLE_SWITCH:
        return "android.widget.Switch";
    case NOGUI_MOBILE_ROLE_TEXT_INPUT:
    case NOGUI_MOBILE_ROLE_SEARCH_INPUT:
        return "android.widget.EditText";
    case NOGUI_MOBILE_ROLE_MULTILINE_TEXT_INPUT:
    case NOGUI_MOBILE_ROLE_TEXT_RUN:
    case NOGUI_MOBILE_ROLE_LABEL:
        return "android.widget.TextView";
    case NOGUI_MOBILE_ROLE_IMAGE:
        return "android.widget.ImageView";
    case NOGUI_MOBILE_ROLE_LIST:
    case NOGUI_MOBILE_ROLE_LIST_BOX:
        return "android.widget.ListView";
    case NOGUI_MOBILE_ROLE_LIST_ITEM:
        return "android.view.View";
    case NOGUI_MOBILE_ROLE_SLIDER:
    case NOGUI_MOBILE_ROLE_SPIN_BUTTON:
        return "android.widget.SeekBar";
    case NOGUI_MOBILE_ROLE_PROGRESS_INDICATOR:
        return "android.widget.ProgressBar";
    case NOGUI_MOBILE_ROLE_SCROLL_VIEW:
        return "android.widget.ScrollView";
    case NOGUI_MOBILE_ROLE_TOOLBAR:
        return "android.widget.Toolbar";
    case NOGUI_MOBILE_ROLE_TAB:
    case NOGUI_MOBILE_ROLE_TAB_LIST:
    case NOGUI_MOBILE_ROLE_TAB_PANEL:
        return "android.view.View";
    case NOGUI_MOBILE_ROLE_DIALOG:
        return "android.app.Dialog";
    default:
        return "android.view.View";
    }
}

/* Decimal, for the resource-name string a node carries. */
static size_t nogui_decimal(char *out, size_t cap, int32_t value)
{
    char digits[12];
    size_t count = 0;
    uint32_t magnitude = value < 0 ? (uint32_t)(-(int64_t)value) : (uint32_t)value;
    do {
        digits[count++] = (char)('0' + (magnitude % 10u));
        magnitude /= 10u;
    } while (magnitude != 0);
    size_t used = 0;
    if (value < 0 && used + 1 < cap) {
        out[used++] = '-';
    }
    while (count > 0 && used + 1 < cap) {
        out[used++] = digits[--count];
    }
    if (used < cap) {
        out[used] = '\0';
    }
    return used;
}

/*
 * One published node, as a real `AccessibilityNodeInfo`.
 *
 * The lock is held by the caller for the whole of this, so every fact read here
 * belongs to the same tree as every other fact read here.
 */
static jobject nogui_build_node(JNIEnv *env, nogui_mobile_bridge *bridge, int32_t native_id)
{
    const nogui_android_tree *tree = bridge->tree;
    if (tree == NULL || bridge->host_view == NULL) {
        return NULL;
    }
    int32_t index = nogui_tree_find(tree, native_id);
    if (index < 0) {
        /* An id the framework retained from an earlier tree. It resolves to
         * nothing, which is the only honest answer: addressing whatever node
         * happens to hold a similar id would drive the wrong control. */
        return NULL;
    }
    const nogui_mobile_node *entry = &tree->nodes[(size_t)index];
    struct nogui_android_jni *jni = &bridge->jni;

    jobject info = (*env)->CallStaticObjectMethod(
        env, jni->node_info_class, jni->node_info_obtain_host, bridge->host_view, (jint)native_id);
    if ((*env)->ExceptionCheck(env) || info == NULL) {
        nogui_clear_exception(env);
        return NULL;
    }

    nogui_set_text(env, jni->node_info_set_class_name, info,
                   nogui_class_name(entry->role), strlen(nogui_class_name(entry->role)));

    if (jni->node_info_set_package_name != NULL && bridge->package_name != NULL) {
        /* The app's own package, read at attach. A node announced as belonging
         * to another app would be a claim this shim cannot make. */
        (*env)->CallVoidMethod(env, info, jni->node_info_set_package_name, bridge->package_name);
        nogui_clear_exception(env);
    }

    /* `text` is what a screen reader reads; `contentDescription` is the platform's
     * alternative channel. A text run carries its text, and the node's name
     * takes the description, falling back to the value, then the placeholder,
     * then the hint. One channel is chosen rather than three written in turn,
     * because a later write would silently replace an earlier one and the node
     * would then announce only the last thing the app published. */
    nogui_set_text(env, jni->node_info_set_text, info, entry->text, entry->text_len);
    const char *description = entry->label;
    size_t description_len = entry->label_len;
    if (description == NULL || description_len == 0) {
        description = entry->value;
        description_len = entry->value_len;
    }
    if (description == NULL || description_len == 0) {
        description = entry->placeholder;
        description_len = entry->placeholder_len;
    }
    if (description == NULL || description_len == 0) {
        description = entry->hint;
        description_len = entry->hint_len;
    }
    nogui_set_text(env, jni->node_info_set_content_description, info, description, description_len);
    /* The hint has a channel of its own, and it is where a screen reader looks
     * for "what this field is for" without confusing it with the field's value. */
    nogui_set_text(env, jni->node_info_set_hint_text, info, entry->hint, entry->hint_len);

    /* The core published these in physical SDL-window pixels, which is the space
     * the framework measures in, so nothing is scaled here. The one adjustment
     * is the host view's own position on screen, measured at attach: bounds are
     * relative to the window and `setBoundsInScreen` wants screen coordinates,
     * and a window that sits below a status bar has a surface origin that is not
     * the decor view's. */
    if (jni->node_info_set_bounds_in_screen != NULL) {
        jint x0 = (jint)entry->bounds.x0 + (jint)bridge->origin_x;
        jint y0 = (jint)entry->bounds.y0 + (jint)bridge->origin_y;
        jint x1 = (jint)entry->bounds.x1 + (jint)bridge->origin_x;
        jint y1 = (jint)entry->bounds.y1 + (jint)bridge->origin_y;
        jobject rect = (*env)->NewObject(
            env, jni->rect_class, jni->rect_ctor, x0, y0, x1, y1);
        if ((*env)->ExceptionCheck(env)) {
            nogui_clear_exception(env);
        } else if (rect != NULL) {
            (*env)->CallVoidMethod(env, info, jni->node_info_set_bounds_in_screen, rect);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, rect);
        }
    }

    if (jni->node_info_set_enabled != NULL) {
        (*env)->CallVoidMethod(env, info, jni->node_info_set_enabled,
            (entry->states & NOGUI_MOBILE_STATE_DISABLED) != 0 ? JNI_FALSE : JNI_TRUE);
    }
    if (jni->node_info_set_visible_to_user != NULL) {
        /* A hidden node is one the app is not showing. Announcing it as visible
         * is a claim the app already contradicts on screen. */
        (*env)->CallVoidMethod(env, info, jni->node_info_set_visible_to_user,
            (entry->states & NOGUI_MOBILE_STATE_HIDDEN) != 0 ? JNI_FALSE : JNI_TRUE);
    }
    if (jni->node_info_set_focused != NULL) {
        (*env)->CallVoidMethod(env, info, jni->node_info_set_focused,
            (entry->states & NOGUI_MOBILE_STATE_FOCUSED) != 0 ? JNI_TRUE : JNI_FALSE);
    }
    if (jni->node_info_set_focusable != NULL) {
        /* Focusable is exactly the core's own focus action, so a node the app
         * never made focusable is never offered focus by the platform either. */
        (*env)->CallVoidMethod(env, info, jni->node_info_set_focusable,
            (entry->actions & (1u << NOGUI_MOBILE_ACTION_FOCUS)) != 0 ? JNI_TRUE : JNI_FALSE);
    }
    if (jni->node_info_set_selected != NULL) {
        (*env)->CallVoidMethod(env, info, jni->node_info_set_selected,
            (entry->states & NOGUI_MOBILE_STATE_SELECTED) != 0 ? JNI_TRUE : JNI_FALSE);
    }
    if (jni->node_info_set_editable != NULL) {
        /* Editable follows the text-selection action, which is what turns a
         * published run into something a screen reader can put a caret in, and
         * a read-only node is not that. */
        jboolean editable = (entry->actions & (1u << NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION)) != 0
                         && (entry->states & NOGUI_MOBILE_STATE_READ_ONLY) == 0;
        (*env)->CallVoidMethod(env, info, jni->node_info_set_editable, editable);
    }
    if (jni->node_info_set_content_invalid != NULL) {
        (*env)->CallVoidMethod(env, info, jni->node_info_set_content_invalid,
            (entry->states & NOGUI_MOBILE_STATE_INVALID) != 0 ? JNI_TRUE : JNI_FALSE);
    }
    if (jni->node_info_set_live_region != NULL && jni->live_region_polite != 0
            && (entry->states & NOGUI_MOBILE_STATE_LIVE_REGION) != 0) {
        (*env)->CallVoidMethod(env, info, jni->node_info_set_live_region, jni->live_region_polite);
    }
    if (entry->states & (NOGUI_MOBILE_STATE_CHECKED_ON | NOGUI_MOBILE_STATE_CHECKED_OFF
                       | NOGUI_MOBILE_STATE_CHECKED_MIXED)) {
        if (jni->node_info_set_checkable != NULL) {
            (*env)->CallVoidMethod(env, info, jni->node_info_set_checkable, JNI_TRUE);
        }
        if (jni->node_info_set_checked != NULL) {
            /* The platform has a boolean, not the core's three states. A mixed
             * node is published unchecked: announcing a mixed control as
             * checked would be a different and wrong fact. */
            (*env)->CallVoidMethod(env, info, jni->node_info_set_checked,
                (entry->states & NOGUI_MOBILE_STATE_CHECKED_ON) != 0 ? JNI_TRUE : JNI_FALSE);
        }
    }

    /* The range is only as wide as the app said it is. A node that published a
     * value but no range gets a current value and no invented minimum and
     * maximum, because a range of zero to zero is a claim about the control. */
    if (entry->has_numeric_value && jni->node_info_set_range_info != NULL
            && jni->range_info_obtain != NULL) {
        jobject range = (*env)->CallStaticObjectMethod(env, jni->range_info_class, jni->range_info_obtain);
        if ((*env)->ExceptionCheck(env)) {
            nogui_clear_exception(env);
        } else if (range != NULL) {
            if (entry->has_numeric_range && jni->range_info_set_min != NULL) {
                (*env)->CallVoidMethod(env, range, jni->range_info_set_min, (jfloat)entry->min_numeric_value);
            }
            if (entry->has_numeric_range && jni->range_info_set_max != NULL) {
                (*env)->CallVoidMethod(env, range, jni->range_info_set_max, (jfloat)entry->max_numeric_value);
            }
            if (jni->range_info_set_current != NULL) {
                (*env)->CallVoidMethod(env, range, jni->range_info_set_current, (jfloat)entry->numeric_value);
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_set_range_info, range);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, range);
        }
    }

    /* A node that holds rows says so, with the count the app published. */
    if (entry->has_set && jni->node_info_set_collection_info != NULL
            && jni->collection_info_obtain != NULL) {
        jobject collection = (*env)->CallStaticObjectMethod(
            env, jni->collection_info_class, jni->collection_info_obtain);
        if ((*env)->ExceptionCheck(env)) {
            nogui_clear_exception(env);
        } else if (collection != NULL) {
            if (jni->collection_info_set_row_count != NULL) {
                (*env)->CallVoidMethod(env, collection, jni->collection_info_set_row_count,
                                       (jint)entry->set_size);
            }
            if (jni->collection_info_set_row_index != NULL) {
                (*env)->CallVoidMethod(env, collection, jni->collection_info_set_row_index,
                                       (jint)entry->set_position);
            }
            if (jni->collection_info_set_column_count != NULL) {
                (*env)->CallVoidMethod(env, collection, jni->collection_info_set_column_count, (jint)1);
            }
            if (jni->collection_info_set_row_index_is_set != NULL) {
                (*env)->CallVoidMethod(env, collection, jni->collection_info_set_row_index_is_set,
                                       JNI_TRUE);
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_set_collection_info, collection);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, collection);
        }
    }

    /* A row of a list is announced with its position, and it takes the row
     * count from the list it belongs to rather than inventing one. */
    if (tree->member_id[(size_t)index] != 0 && jni->node_info_set_collection_item_info != NULL
            && jni->collection_item_info_obtain != NULL) {
        int32_t owner = nogui_tree_find(tree, tree->member_id[(size_t)index]);
        const nogui_mobile_node *list = owner >= 0 ? &tree->nodes[(size_t)owner] : NULL;
        jobject item = (*env)->CallStaticObjectMethod(
            env, jni->collection_item_info_class, jni->collection_item_info_obtain);
        if ((*env)->ExceptionCheck(env)) {
            nogui_clear_exception(env);
        } else if (item != NULL) {
            if (jni->collection_item_info_set_row_index != NULL) {
                (*env)->CallVoidMethod(env, item, jni->collection_item_info_set_row_index,
                                       (jint)entry->set_position);
            }
            if (jni->collection_item_info_set_row_count != NULL) {
                (*env)->CallVoidMethod(env, item, jni->collection_item_info_set_row_count,
                                       (jint)(list != NULL ? list->set_size : 0));
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_set_collection_item_info, item);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, item);
        }
    }

    /* The children, as ids. This is how the framework learns what to ask for
     * next: it walks the ids attached here and calls back for each one, and an
     * id that has since been retired answers with no node at all. */
    if (jni->node_info_add_child != NULL) {
        int32_t start = tree->child_start[(size_t)index];
        for (int32_t slot = 0; slot < entry->children_len; ++slot) {
            int32_t child = tree->child_ids[(size_t)start + (size_t)slot];
            if (child <= 0) {
                continue;
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_add_child, bridge->host_view, (jint)child);
            nogui_clear_exception(env);
        }
    }

    /* The action mask decides what is offered. A node the app will not act on
     * publishes an empty mask, so it is offered nothing at all rather than an
     * action the app would refuse. */
    if (jni->node_info_add_action != NULL) {
        jclass action_class = jni->action_class;
        jmethodID ctor = jni->action_ctor;
        struct {
            jint id;
            uint8_t core;
        } offered[] = {
            { jni->action_click, NOGUI_MOBILE_ACTION_CLICK },
            { jni->action_focus, NOGUI_MOBILE_ACTION_FOCUS },
            { jni->action_clear_focus, NOGUI_MOBILE_ACTION_BLUR },
            { jni->action_expand, NOGUI_MOBILE_ACTION_EXPAND },
            { jni->action_collapse, NOGUI_MOBILE_ACTION_COLLAPSE },
            { jni->action_scroll_forward, NOGUI_MOBILE_ACTION_SCROLL_DOWN },
            { jni->action_scroll_backward, NOGUI_MOBILE_ACTION_SCROLL_UP },
            { jni->action_set_text, NOGUI_MOBILE_ACTION_REPLACE_SELECTED_TEXT },
            { jni->action_set_selection, NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION },
            { jni->action_show_on_screen, NOGUI_MOBILE_ACTION_SCROLL_INTO_VIEW },
            { jni->action_set_progress, NOGUI_MOBILE_ACTION_SET_VALUE },
        };
        for (size_t slot = 0; slot < sizeof(offered) / sizeof(offered[0]); ++slot) {
            if (offered[slot].id == 0) {
                /* This platform does not have that action, so there is nothing
                 * to offer and nothing to perform later. */
                continue;
            }
            if ((entry->actions & (1u << offered[slot].core)) == 0) {
                continue;
            }
            jobject action = (*env)->NewObject(
                env, action_class, ctor, offered[slot].id, NULL);
            if ((*env)->ExceptionCheck(env)) {
                nogui_clear_exception(env);
                continue;
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_add_action, action);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, action);
        }
    }

    /* A named action is announced by its name, so the name has to cross into
     * Java rather than being flattened into the built-in mask. The platform id
     * is the shim's own; what the app published is resolved from the slot when
     * the action comes back. */
    if (entry->custom_actions != NULL && jni->node_info_add_action != NULL
            && jni->action_class != NULL && jni->action_ctor != NULL) {
        for (size_t slot = 0; slot < entry->custom_actions_len; ++slot) {
            const nogui_mobile_custom_action *named = &entry->custom_actions[slot];
            int32_t id = nogui_custom_action_id((int32_t)slot);
            if (id == 0 || named->name == NULL || named->name_len == 0) {
                continue;
            }
            int32_t status = NOGUI_MOBILE_OK;
            jstring label = nogui_jstring(env, named->name, named->name_len, &status);
            if (label == NULL) {
                continue;
            }
            jobject action = (*env)->NewObject(env, jni->action_class, jni->action_ctor, (jint)id, label);
            (*env)->DeleteLocalRef(env, label);
            if ((*env)->ExceptionCheck(env)) {
                nogui_clear_exception(env);
                continue;
            }
            (*env)->CallVoidMethod(env, info, jni->node_info_add_action, action);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, action);
        }
    }

    /* The caret the core published, in the unit Android states it in. A run
     * that published no character table is not addressable there, so no
     * selection is claimed for it. */
    if (jni->node_info_set_text_selection != NULL && entry->text != NULL
            && entry->text_selection_anchor >= 0 && entry->text_selection_focus >= 0) {
        int32_t start = 0;
        int32_t end = 0;
        if (nogui_utf16_of_char(entry->text, entry->text_len, entry->text_selection_anchor, &start) == NOGUI_MOBILE_OK
            && nogui_utf16_of_char(entry->text, entry->text_len, entry->text_selection_focus, &end) == NOGUI_MOBILE_OK) {
            (*env)->CallVoidMethod(env, info, jni->node_info_set_text_selection, (jint)start, (jint)end);
            nogui_clear_exception(env);
        }
    }

    /* A stable name for the node in the platform's own resource-name field, so
     * a diagnostic that prints it prints the identity the framework holds rather
     * than a position that changes on the next reorder. */
    if (jni->node_info_set_view_id != NULL) {
        /* The prefix is spelled out rather than measured, so the space left for
         * the id is exactly what is left after the prefix and there is no
         * arithmetic to get wrong. A native id is at most ten digits and always
         * positive, so the buffer cannot overflow. */
        static const char prefix[] = "nogui:node/";
        char name[sizeof(prefix) + 12];
        size_t length = 0;
        while (prefix[length] != '\0') {
            name[length] = prefix[length];
            length += 1;
        }
        length += nogui_decimal(name + length, (sizeof(name) - 1) - length, native_id);
        int32_t status = NOGUI_MOBILE_OK;
        jstring value = nogui_jstring(env, name, length, &status);
        if (value != NULL) {
            (*env)->CallVoidMethod(env, info, jni->node_info_set_view_id, value);
            nogui_clear_exception(env);
            (*env)->DeleteLocalRef(env, value);
        }
    }

    nogui_clear_exception(env);
    return info;
}

/* ── E05: performing an action ────────────────────────────────────────────── */

/*
 * The core's own action number for a framework action id, or 0xFF when this
 * framework asked for something the model does not describe.
 *
 * The mapping is "the framework asked for X, the core has X" rather than a
 * numeric coincidence, and each side's id is read from the framework at attach.
 * An id nothing here claims is refused rather than forwarded as a guess, so a
 * screen reader can never drive an action the app has no path for.
 */
static uint8_t nogui_core_action(const struct nogui_android_jni *jni, jint action_id)
{
    if (action_id == 0) {
        /* A member this framework does not have resolved to zero, and no real
         * framework action is zero, so a zero here means "not something this
         * bridge maps" rather than "the first action". */
        return 0xFFu;
    }
    if (action_id == jni->action_click) {
        return NOGUI_MOBILE_ACTION_CLICK;
    }
    if (action_id == jni->action_focus) {
        return NOGUI_MOBILE_ACTION_FOCUS;
    }
    if (action_id == jni->action_clear_focus) {
        return NOGUI_MOBILE_ACTION_BLUR;
    }
    if (action_id == jni->action_expand) {
        return NOGUI_MOBILE_ACTION_EXPAND;
    }
    if (action_id == jni->action_collapse) {
        return NOGUI_MOBILE_ACTION_COLLAPSE;
    }
    if (action_id == jni->action_scroll_forward) {
        return NOGUI_MOBILE_ACTION_SCROLL_DOWN;
    }
    if (action_id == jni->action_scroll_backward) {
        return NOGUI_MOBILE_ACTION_SCROLL_UP;
    }
    if (action_id != 0 && action_id == jni->action_show_on_screen) {
        return NOGUI_MOBILE_ACTION_SCROLL_INTO_VIEW;
    }
    if (action_id != 0 && action_id == jni->action_set_progress) {
        return NOGUI_MOBILE_ACTION_SET_VALUE;
    }
    return 0xFFu;
}

/*
 * Hand a request to the host.
 *
 * The callback runs with the lock already dropped and after this frame's claim
 * on the bridge is given up, so a host that answers the request by publishing a
 * new tree cannot deadlock against the call that produced it, and a free racing
 * with it cannot return into storage the callback is still reading. The
 * function pointer and the context are read before the claim is dropped,
 * because after it the bridge may be gone.
 *
 * Everything the request points at is this frame's own storage or the caller's,
 * which is exactly the borrow this ABI promises: valid for the duration of the
 * callback and not one moment longer.
 */
static void nogui_emit(
    nogui_mobile_action_fn on_action,
    void *user,
    int32_t slot,
    const nogui_mobile_request *request)
{
    nogui_android_unclaim(slot);
    if (on_action != NULL) {
        on_action(user, request);
    }
}

/* ── E05: the provider's JNI entry points ─────────────────────────────────── */

/*
 * These are the functions the Java shim declares `native`. The names are the JNI
 * mangling of `org.libsdl.app.NoguiAccessibilityProvider`, so the Java
 * declaration and this definition are one contract: a rename on either side is a
 * link error at the point of use, not a silent no-op at runtime.
 *
 * Each of them resolves the handle in the table of live bridges first. That is
 * what makes a provider that outlives its bridge answer "no node" instead of
 * following a freed pointer, and it is why the handle arrives as an argument as
 * well as living in a field.
 */

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeRootId(
    JNIEnv *env, jclass type, jlong handle)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    jint root = bridge->attached && bridge->tree != NULL ? bridge->tree->root : 0;
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return root;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeFocusedId(
    JNIEnv *env, jclass type, jlong handle)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    /* A window that does not hold focus has no accessibility focus to report,
     * and answering with a stale node would announce a caret the user cannot
     * see. */
    jint focus = bridge->attached && bridge->window_focused && bridge->tree != NULL
        ? bridge->tree->focus : 0;
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return focus;
}

JNIEXPORT jobject JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeCreateNode(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id)
{
    (void)type;
    if (env == NULL || virtual_id <= 0) {
        return NULL;
    }
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return NULL;
    }
    nogui_lock_acquire();
    jobject info = bridge->attached ? nogui_build_node(env, bridge, (int32_t)virtual_id) : NULL;
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return info;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeActionMask(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    jint mask = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            mask = (jint)bridge->tree->nodes[(size_t)index].actions;
        }
    }
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return mask;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeChildCount(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    jint count = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            count = (jint)bridge->tree->nodes[(size_t)index].children_len;
        }
    }
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return count;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeChildAt(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint position)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    jint child = 0;
    const nogui_android_tree *tree = bridge->attached ? bridge->tree : NULL;
    int32_t index = tree != NULL ? nogui_tree_find(tree, (int32_t)virtual_id) : -1;
    if (index >= 0 && position >= 0 && position < (jint)tree->nodes[(size_t)index].children_len) {
        int32_t start = tree->child_start[(size_t)index];
        child = tree->child_ids[(size_t)start + (size_t)position];
    }
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return child;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeCustomActionCount(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return 0;
    }
    nogui_lock_acquire();
    jint count = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            count = (jint)bridge->tree->nodes[(size_t)index].custom_actions_len;
        }
    }
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return count;
}

JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeCustomActionSlot(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint action_id)
{
    (void)env;
    (void)type;
    (void)virtual_id;
    /* The platform id a named action is advertised under is the shim's own
     * range, so recognising one needs no tree at all. A custom action is only
     * meaningful for a node, and the entry point that performs it checks that
     * the node is still published and still has that action. */
    return nogui_custom_action_slot((int32_t)action_id);
}

JNIEXPORT jstring JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeCustomActionName(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint position)
{
    (void)type;
    if (env == NULL) {
        return NULL;
    }
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return NULL;
    }
    nogui_lock_acquire();
    const char *name = NULL;
    size_t name_len = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0 && position >= 0) {
            const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
            if (entry->custom_actions != NULL && (size_t)position < entry->custom_actions_len) {
                name = entry->custom_actions[(size_t)position].name;
                name_len = entry->custom_actions[(size_t)position].name_len;
            }
        }
    }
    int32_t status = NOGUI_MOBILE_OK;
    jstring result = name == NULL ? NULL : nogui_jstring(env, name, name_len, &status);
    nogui_lock_release();
    nogui_android_unclaim(slot);
    return result;
}

JNIEXPORT jboolean JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativePerformAction(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint action_id)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return JNI_FALSE;
    }
    nogui_lock_acquire();
    uint8_t core = nogui_core_action(&bridge->jni, action_id);
    if (core == 0xFFu) {
        /* An action the model does not describe. `false` is the platform's own
         * "that control cannot do that", which is the truth. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    if (!bridge->attached || bridge->tree == NULL
            || nogui_tree_find(bridge->tree, (int32_t)virtual_id) < 0) {
        /* The id the framework asked about is gone. No request is produced at
         * all, rather than one aimed at whatever holds a nearby id now. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
    const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
    if ((entry->actions & (1u << core)) == 0) {
        /* The framework offered an action the core published no path for, which
         * is a stale node rather than a live offer. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = core;
    request.target = (uint64_t)virtual_id;
    request.data = NOGUI_MOBILE_DATA_NONE;
    request.anchor_index = -1;
    request.focus_index = -1;
    nogui_mobile_action_fn on_action = bridge->on_action;
    void *user = bridge->user;
    /* The lock is dropped before the host is called: a host that answers by
     * publishing a new tree must not be holding a lock the publish needs. */
    nogui_lock_release();
    nogui_emit(on_action, user, slot, &request);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativePerformCustomAction(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint action_id)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return JNI_FALSE;
    }
    int32_t position = nogui_custom_action_slot((int32_t)action_id);
    if (position < 0) {
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_lock_acquire();
    /* The slot is resolved to the identifier the app published, because that is
     * what the app's model recognises. The platform id the action was advertised
     * under is this shim's own bookkeeping and means nothing to the app.
     *
     * `found` is separate from the value, because an app may legitimately
     * publish the identifier zero, and treating that as "no such action" would
     * silently drop a real one. */
    int32_t found = 0;
    int32_t published = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
            if (entry->custom_actions != NULL && (size_t)position < entry->custom_actions_len) {
                found = 1;
                published = entry->custom_actions[(size_t)position].id;
            }
        }
    }
    if (!found) {
        /* The node is gone, or it no longer publishes an action in this slot.
         * A named action the app has withdrawn is refused rather than aimed at
         * whatever now occupies that position. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = NOGUI_MOBILE_ACTION_CUSTOM;
    request.target = (uint64_t)virtual_id;
    request.data = NOGUI_MOBILE_DATA_CUSTOM_ACTION;
    request.custom_action = published;
    request.anchor_index = -1;
    request.focus_index = -1;
    nogui_mobile_action_fn on_action = bridge->on_action;
    void *user = bridge->user;
    /* The lock is dropped and the claim given up before the host is called, so a
     * host that answers by publishing a new tree cannot deadlock against the
     * call that produced it, and a free racing with it waits rather than
     * returning into storage this frame is still reading. */
    nogui_lock_release();
    nogui_emit(on_action, user, slot, &request);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeSetText(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jstring value)
{
    (void)type;
    if (env == NULL || value == NULL) {
        return JNI_FALSE;
    }
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return JNI_FALSE;
    }
    /* `GetStringChars` and `GetStringLength` rather than `GetStringUTFChars`:
     * the latter returns MODIFIED UTF-8, in which a supplementary character is
     * six bytes and an embedded NUL is two, so a value the screen reader typed
     * would reach the model as something it never received. The length is read
     * first because it is the only honest measure of a Java string, and the
     * borrow is released on every path out of here. */
    jsize units = (*env)->GetStringLength(env, value);
    if (units < 0) {
        nogui_clear_exception(env);
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    const uint16_t *wide = (*env)->GetStringChars(env, value, NULL);
    if (wide == NULL) {
        nogui_clear_exception(env);
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    /* A run of NOGUI_MOBILE_MAX_ACTION_TEXT bytes, plus the terminator, is the
     * most a payload may carry. A longer one is refused rather than truncated,
     * because a half-typed replacement is not what the user asked for. */
    size_t cap = NOGUI_MOBILE_MAX_ACTION_TEXT;
    char *payload = (char *)malloc(cap + 1);
    int32_t converted = NOGUI_MOBILE_ERR_MEMORY;
    size_t len = 0;
    if (payload != NULL) {
        converted = nogui_utf8_from_utf16(wide, (size_t)units, payload, cap, &len);
    }
    (*env)->ReleaseStringChars(env, value, wide);
    nogui_clear_exception(env);
    if (converted != NOGUI_MOBILE_OK) {
        free(payload);
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }

    nogui_lock_acquire();
    int32_t ok = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
            ok = (entry->actions & (1u << NOGUI_MOBILE_ACTION_REPLACE_SELECTED_TEXT)) != 0;
        }
    }
    if (!ok) {
        nogui_lock_release();
        free(payload);
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = NOGUI_MOBILE_ACTION_REPLACE_SELECTED_TEXT;
    request.target = (uint64_t)virtual_id;
    request.data = NOGUI_MOBILE_DATA_VALUE;
    request.value = payload;
    request.value_len = len;
    request.anchor_index = -1;
    request.focus_index = -1;
    nogui_mobile_action_fn on_action = bridge->on_action;
    void *user = bridge->user;
    /* The payload is this frame's own storage and the borrow lasts exactly as
     * long as the callback, which is the contract this ABI states. The lock is
     * dropped first, so a host that edits the model and republishes cannot be
     * holding a lock this frame still needs. */
    nogui_lock_release();
    nogui_emit(on_action, user, slot, &request);
    free(payload);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeSetSelection(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jint start, jint end)
{
    (void)env;
    (void)type;
    if (start < 0 || end < 0) {
        return JNI_FALSE;
    }
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return JNI_FALSE;
    }
    nogui_lock_acquire();
    int32_t ok = 0;
    int64_t anchor = -1;
    int64_t focus = -1;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
            if ((entry->actions & (1u << NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION)) != 0
                    && entry->text != NULL
                    && nogui_char_of_utf16(entry->text, entry->text_len, (int32_t)start, &anchor) == NOGUI_MOBILE_OK
                    && nogui_char_of_utf16(entry->text, entry->text_len, (int32_t)end, &focus) == NOGUI_MOBILE_OK) {
                ok = 1;
            }
        }
    }
    if (!ok) {
        /* A run with no text, no selection action, or an offset that is not a
         * character boundary is refused. The core is never handed a position it
         * cannot address, and nothing is clamped into one. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = NOGUI_MOBILE_ACTION_SET_TEXT_SELECTION;
    request.target = (uint64_t)virtual_id;
    request.data = NOGUI_MOBILE_DATA_TEXT_SELECTION;
    request.anchor_index = anchor;
    request.focus_index = focus;
    nogui_mobile_action_fn on_action = bridge->on_action;
    void *user = bridge->user;
    nogui_lock_release();
    nogui_emit(on_action, user, slot, &request);
    return JNI_TRUE;
}

/*
 * `ACTION_SET_PROGRESS`, as the framework states it.
 *
 * The named action carries the new value in its own bundle rather than as an
 * argument, so it cannot travel the plain id path in `nativePerformAction`:
 * that path built a request with no payload and advertised SET_VALUE anyway,
 * and a request with no payload reached the model with no number and did
 * nothing a person could hear. The Java half reads the bundle and calls this
 * with the value it read, which is the same shape as the text and selection
 * payloads rather than a second convention for a value that arrives.
 *
 * A value the framework did not supply is refused here rather than defaulted:
 * "no argument" is not "set it to zero", and a screen reader told the control
 * jumped to zero is worse than one told nothing happened.
 */
JNIEXPORT jboolean JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeSetValue(
    JNIEnv *env, jclass type, jlong handle, jint virtual_id, jfloat value)
{
    (void)env;
    (void)type;
    int32_t slot = 0;
    nogui_mobile_bridge *bridge = nogui_android_claim((intptr_t)handle, &slot);
    if (bridge == NULL) {
        return JNI_FALSE;
    }
    nogui_lock_acquire();
    int32_t ok = 0;
    if (bridge->attached && bridge->tree != NULL) {
        int32_t index = nogui_tree_find(bridge->tree, (int32_t)virtual_id);
        if (index >= 0) {
            const nogui_mobile_node *entry = &bridge->tree->nodes[(size_t)index];
            ok = (entry->actions & (1u << NOGUI_MOBILE_ACTION_SET_VALUE)) != 0;
        }
    }
    if (!ok) {
        /* The node has left the tree, or the core published no path for setting
         * it. Either way there is nothing this request could be aimed at. */
        nogui_lock_release();
        nogui_android_unclaim(slot);
        return JNI_FALSE;
    }
    nogui_mobile_request request;
    memset(&request, 0, sizeof(request));
    request.action = NOGUI_MOBILE_ACTION_SET_VALUE;
    request.target = (uint64_t)virtual_id;
    request.data = NOGUI_MOBILE_DATA_NUMERIC_VALUE;
    request.number = (double)value;
    request.anchor_index = -1;
    request.focus_index = -1;
    nogui_mobile_action_fn on_action = bridge->on_action;
    void *user = bridge->user;
    nogui_lock_release();
    nogui_emit(on_action, user, slot, &request);
    return JNI_TRUE;
}


/*
 * Measure the window, on Android's UI thread.
 *
 * The Java half posts this through `Activity.runOnUiThread` and waits, because
 * the window, its insets and the activity's decor view all belong to the UI
 * thread and SDL's native thread is not it. Everything this writes is the
 * framework's own reading of the real window, taken here where the objects are
 * in hand; nothing is carried over from an earlier call and nothing is derived
 * from a fact this platform did not publish.
 *
 * The discrete facts and the geometry cross in two arrays because a task on
 * another thread has no other way to return a value, and because a measurement
 * squeezed into an integer would lose the fraction that separates a logical
 * point from a pixel. A fact the platform did not answer stays zero and is
 * reported as absent by the entry point that received it, never as a "no".
 */
JNIEXPORT jint JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeMeasureOnUi(
    JNIEnv *env, jclass type, jint op, jobject activity, jlongArray out_long, jdoubleArray out_double)
{
    (void)type;
    if (env == NULL || activity == NULL || out_long == NULL || out_double == NULL) {
        return NOGUI_MOBILE_ERR_ARGUMENT;
    }
    /* The member table is resolved here rather than carried in, because this
     * runs on a thread that may never have looked one up and a member lookup is
     * the one thing that must be done on a thread with a live class loader. */
    struct nogui_android_jni jni;
    memset(&jni, 0, sizeof(jni));
    int32_t status = nogui_resolve_window(env, &jni);
    if (status != NOGUI_MOBILE_OK) {
        nogui_release_jni(env, &jni);
        return status;
    }
    if (op == NOGUI_ANDROID_OP_DEFER_BACK) {
        /* The one operation on this hop that is an effect rather than a
         * reading, so it answers before anything is measured and through the
         * same arrays. `moveTaskToBack` is what the framework itself does with
         * a back press no activity consumed, and it belongs to the UI thread
         * like the window does, which is why it runs here and not on the
         * caller's. */
        jboolean moved = JNI_FALSE;
        if (jni.activity_move_task_to_back != NULL) {
            moved = (*env)->CallBooleanMethod(env, activity, jni.activity_move_task_to_back, JNI_TRUE);
            nogui_clear_exception(env);
        }
        nogui_release_jni(env, &jni);
        jlong moved_fact = (moved == JNI_TRUE) ? 1 : 0;
        (*env)->SetLongArrayRegion(env, out_long, 0, 1, &moved_fact);
        jdouble no_geometry[NOGUI_ANDROID_MEASURE_DOUBLES];
        memset(no_geometry, 0, sizeof(no_geometry));
        (*env)->SetDoubleArrayRegion(env, out_double, 0, NOGUI_ANDROID_MEASURE_DOUBLES, no_geometry);
        return moved == JNI_TRUE ? NOGUI_MOBILE_OK : NOGUI_MOBILE_ERR_REFUSED;
    }
    nogui_android_window reading;
    /* Both operations read the same object, so one pass answers both and a
     * caller that wants the keyboard still learns the insets it measured beside
     * it. */
    (void)nogui_read_window(env, &jni, activity, &reading);
    nogui_release_jni(env, &jni);

    jlong facts[NOGUI_ANDROID_MEASURE_LONGS];
    jdouble geometry[NOGUI_ANDROID_MEASURE_DOUBLES];
    memset(facts, 0, sizeof(facts));
    memset(geometry, 0, sizeof(geometry));
    facts[0] = reading.insets_measured;
    facts[1] = reading.keyboard_answered;
    facts[2] = reading.keyboard_supported;
    facts[3] = reading.keyboard_visible;
    facts[4] = reading.frame_measured;
    geometry[0] = reading.insets.left;
    geometry[1] = reading.insets.top;
    geometry[2] = reading.insets.right;
    geometry[3] = reading.insets.bottom;
    geometry[4] = reading.frame.x0;
    geometry[5] = reading.frame.y0;
    geometry[6] = reading.frame.x1;
    geometry[7] = reading.frame.y1;
    (*env)->SetLongArrayRegion(env, out_long, 0, NOGUI_ANDROID_MEASURE_LONGS, facts);
    (*env)->SetDoubleArrayRegion(env, out_double, 0, NOGUI_ANDROID_MEASURE_DOUBLES, geometry);
    nogui_clear_exception(env);
    /* The op chooses which of the two questions this call is answering. A call
     * that asked about the insets still succeeds when the keyboard could not be
     * measured, because those are two questions and one of them was answered. */
    if (op == NOGUI_ANDROID_OP_INSETS) {
        return reading.insets_measured ? NOGUI_MOBILE_OK : NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    if (op == NOGUI_ANDROID_OP_KEYBOARD) {
        return reading.keyboard_answered ? NOGUI_MOBILE_OK : NOGUI_MOBILE_ERR_UNAVAILABLE;
    }
    return NOGUI_MOBILE_ERR_ARGUMENT;
}
JNIEXPORT void JNICALL
Java_org_libsdl_app_NoguiAccessibilityProvider_nativeSetTrimMemory(
    JNIEnv *env, jclass type, jint level)
{
    (void)env;
    (void)type;
    nogui_android_record_trim(level);
}
