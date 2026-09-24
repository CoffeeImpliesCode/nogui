package org.libsdl.app;

import android.app.Activity;
import android.os.Bundle;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * The object Android's accessibility framework talks to, and the bridge's way
 * onto Android's UI thread.
 *
 * <p>Why this file exists. {@link AccessibilityNodeProvider} is a Java class with
 * no C entry point that produces one, and {@link AccessibilityNodeInfo} is the
 * same. The framework reaches a provider through
 * {@link View#getAccessibilityNodeProvider()}, so the view hierarchy has to hand
 * one back. This class is that provider, and it is installed with public API
 * only: {@link View#setAccessibilityDelegate} with a delegate whose
 * {@code getAccessibilityNodeProvider} returns the instance below. No hidden
 * field is touched, no view class is replaced, and no view is added to the
 * hierarchy.
 *
 * <p>It is installed on the view SDL actually renders into, found by walking the
 * window's own hierarchy with public API. That is not a stylistic choice: the
 * framework attributes a virtual hierarchy to the view whose provider it reads,
 * and a node's bounds are relative to the window the app draws in, so rooting
 * the provider anywhere else makes every screen reader highlight land in the
 * wrong place. A window with no such view, or with more than one, is refused.
 *
 * <p>Units. On Android every rectangle crossing the bridge is in physical
 * SDL-window pixels, which is what the framework measures in. Neither half
 * applies a scale: display density is not the scale SDL renders at, and the host
 * is the only layer that observed the real one.
 *
 * <p>Why this file also marshals. SDL's native main thread is NOT Android's UI
 * thread. An app's {@code main} runs on a thread SDL starts, while the window,
 * its insets and the activity's own views belong to the UI thread, and touching
 * any of them from the wrong one is a race Android documents no way to
 * win. So every operation that needs the UI thread is posted there and waited
 * for under a bound, and a bound that is not met is reported as a refusal
 * rather than waited out forever. A caller already on the UI thread pays nothing
 * for the round trip, because {@code runOnUiThread} runs the work inline there.
 *
 * <p>What crosses the boundary, and what does not. The static {@code *OnUiThread}
 * methods are called by the C half from SDL's thread; they post to the UI thread
 * and wait. The work they post touches only Java objects — a provider, a view, a
 * delegate, two arrays — and never C memory. That is what makes a hop that
 * misses its bound harmless: whatever is still queued finishes on its own against
 * objects that outlive it, and the C half is free to release its own storage the
 * moment the call returns. The actual JNI work stays in {@code nogui_android.c},
 * reached from the posted runnable through the {@code native*} declarations.
 *
 * <p>This class interprets no semantic fact. What a node IS comes from the C
 * half, which owns the published tree and translates it into a real
 * {@link AccessibilityNodeInfo}; what a node DOES comes from the action mask the
 * core published, which the C half also checks before forwarding anything. A
 * method here that could answer from its own state would be a second
 * implementation of the semantics, and there is one already.
 *
 * <p>Identity. The framework addresses a virtual node by a signed 32-bit
 * {@code virtualViewId}, and a node's identity on screen is the pair (host view,
 * virtual id) — {@code AccessibilityNodeInfo.makeNodeId(accessibilityViewId,
 * virtualDescendantId)}. The virtual id here is therefore the core's own
 * {@code native_id}: positive, at or below {@link Integer#MAX_VALUE}, issued
 * once per semantic identity and never reused while the bridge lives. Because it
 * is a name and not a position, a reorder costs nothing, and an id the framework
 * retained from an earlier tree can only ever resolve to the node it was issued
 * for — or to nothing, once that node is gone, which is what the C half answers.
 *
 * <p>Ownership. The {@code bridge} field is an opaque pointer into the C adapter,
 * never dereferenced here. It is cleared before the C half releases that memory,
 * so a framework call arriving after teardown sees zero and answers "no node"
 * instead of reaching freed storage. The delegate this class installs replaces
 * one the view may already have had, and that one is put back on removal, so a
 * view with accessibility behaviour of its own gets it back rather than losing
 * it to this bridge.
 *
 * <p>This file is compiled into the application's DEX by the app's own build,
 * beside SDL's own Java layer. It is not part of the Zig build. The two halves
 * are joined by the JNI names in {@code nogui_android.c}, which are the
 * mangling of this class's name and its {@code native} methods, so a rename on
 * either side is a link error rather than a silent no-op.
 */
public class NoguiAccessibilityProvider extends AccessibilityNodeProvider {
    /**
     * How long a UI-thread hop may be waited for.
     *
     * <p>Bounded on purpose. The caller is SDL's native thread, which is not the
     * thread the UI has to stay responsive for, and a hop that never completes
     * would stall the host for as long as the UI thread stays busy. Exceeding
     * the bound is reported to the caller as a refusal it can act on, rather
     * than waited out silently.
     */
    private static final long UI_TIMEOUT_MS = 2000L;

    /* The window measurements the C half asks for. The values are a contract
     * with nogui_android.c and are named on both sides. */
    /** The window's safe-area insets, in logical points. */
    static final int OP_INSETS = 1;
    /** The window's soft keyboard, in logical points. */
    static final int OP_KEYBOARD = 2;
    /**
     * Hand a back request back to the system.
     *
     * <p>Travels the same hop as the two measurements because it belongs to the
     * same thread: the activity is not ours to move from any other one. It is
     * the one operation here that is an effect rather than a reading, and the
     * framework's own answer comes back through the same arrays.
     */
    static final int OP_DEFER_BACK = 3;

    /** The C adapter, or 0 once it is detached. */
    private long bridge;
    /** The view this virtual hierarchy is rooted at, or null once detached. */
    private View host;
    /** The delegate that view carried before this one replaced it. */
    private View.AccessibilityDelegate previous;
    /** The provider the C half built and is about to install, if any. */
    private static NoguiAccessibilityProvider pending;
    /** The provider the last successful install put on a view, and the view it
     * landed on. Kept so the removal names the same pair the install did. */
    private static NoguiAccessibilityProvider s_installedProvider;
    private static View s_installedHost;

    /* ── the native contract ───────────────────────────────────────────────
     *
     * Every entry point takes the bridge handle as an argument even though the
     * instance also holds it, because the C half resolves the handle through its
     * own table of live bridges and answers "not live" for a handle it no longer
     * knows. A Java-side field alone could not tell a stale handle from a
     * current one.
     *
     * `virtualViewId` is the core's native id on every call, and it is the same
     * value the node was created with, so the framework addresses a node again
     * with the id it was first handed. */

    /** The published root's native id, or 0 when there is no published root. */
    private static native int nativeRootId(long handle);
    /** The focused node's native id, or 0 when the core published no focus. */
    private static native int nativeFocusedId(long handle);
    /** A real node for one native id, or null when that id is not published. */
    private static native AccessibilityNodeInfo nativeCreateNode(long handle, int virtualViewId);
    /** The core's action mask for one native id, or 0 when it is not published. */
    private static native int nativeActionMask(long handle, int virtualViewId);
    /** How many children one native id currently has. */
    private static native int nativeChildCount(long handle, int virtualViewId);
    /** The `position`-th child of one native id, as a native id, or 0. */
    private static native int nativeChildAt(long handle, int virtualViewId, int position);
    /** A real framework action on a real node. */
    private static native boolean nativePerformAction(long handle, int virtualViewId, int actionId);
    /** A text replacement, as ACTION_SET_TEXT carries it. */
    private static native boolean nativeSetText(long handle, int virtualViewId, String value);
    /** A selection, as ACTION_SET_SELECTION carries it, in UTF-16 code units. */
    private static native boolean nativeSetSelection(long handle, int virtualViewId, int start, int end);
    /** How many named actions one node published. */
    private static native int nativeCustomActionCount(long handle, int virtualViewId);
    /** The label a screen reader announces for one named action. */
    private static native String nativeCustomActionName(long handle, int virtualViewId, int slot);
    /** The slot a performed action id names, or -1 when it names no custom action. */
    private static native int nativeCustomActionSlot(long handle, int virtualViewId, int actionId);
    /** A named action, addressed by the platform id the shim advertised. */
    private static native boolean nativePerformCustomAction(long handle, int virtualViewId, int actionId);
    /** Platform level in, {@code NOGUI_MOBILE_ANDROID_TRIM_*} out. */
    private static native void nativeSetTrimMemory(int level);

    /**
     * A control's new numeric value, as ACTION_SET_PROGRESS carries it.
     *
     * <p>This is a named action rather than an int constant, so its payload
     * arrives in the bundle the framework passes and cannot travel the id path
     * {@code nativePerformAction} uses. Asking for it here and handing over the
     * value keeps the same shape as the text and selection payloads.
     */
    private static native boolean nativeSetValue(long handle, int virtualViewId, float value);

    /**
     * The id the running framework gives ACTION_SET_PROGRESS.
     *
     * <p>Read once, and zero on a framework that has no such action, which is
     * also why a zero never matches: no real framework action id is zero. The
     * C half published the action under this same value, so the two agree
     * without the numbering being restated on either side.
     */
    private static final int SET_PROGRESS_ID = setProgressId();

    private static int setProgressId() {
        if (android.os.Build.VERSION.SDK_INT < 24) {
            return 0;
        }
        return AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.getId();
    }

    /**
     * Measures the window. Runs on the UI thread, inside a posted hop.
     *
     * <p>Everything this fills is the framework's own measurement of the real
     * window. Nothing here is derived from a previous reading, and a fact the
     * platform does not publish on this API level is left absent rather than
     * approximated.
     */
    private static native int nativeMeasureOnUi(int op, Object activity, long[] outLong, double[] outDouble);

    /* ── the UI-thread hop ─────────────────────────────────────────────────── */

    /**
     * One bounded round trip onto the UI thread.
     *
     * <p>{@code Activity.runOnUiThread} runs {@code work} inline when the caller
     * is already on the UI thread and posts it otherwise, so this is correct
     * from either side and costs nothing when the caller is already there. The
     * latch turns the post into a bounded wait, so the caller's thread is never
     * parked forever on a UI thread that is busy.
     *
     * <p>Returns false when the UI thread did not service the work within the
     * bound. That is not a claim that the work failed: it may still run later,
     * which is safe because it only touches objects the runnable holds.
     */
    private static boolean onUiThread(Activity activity, Runnable work) {
        if (activity == null) {
            return false;
        }
        final CountDownLatch done = new CountDownLatch(1);
        final boolean[] ran = new boolean[1];
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    work.run();
                    ran[0] = true;
                } finally {
                    done.countDown();
                }
            }
        });
        try {
            if (!done.await(UI_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                return false;
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return false;
        }
        return ran[0];
    }

    /**
     * Reads one window measurement on the UI thread and waits for it.
     *
     * <p>Called by the C half. The out-parameters are plain arrays because a
     * task posted to another thread cannot return a value any other way, and an
     * array is the one shape both Java and JNI handle without an object graph.
     * A refusal that happened on the UI thread is returned unchanged rather than
     * being flattened into "the hop timed out".
     *
     * <p>Returns {@code NOGUI_MOBILE_ERR_THREAD} (-1) when the bound was not met,
     * which is the code the C half reports for "this could not run on Android's
     * UI thread".
     */
    static int measureOnUiThread(final Activity activity, final int op,
            final long[] outLong, final double[] outDouble) {
        final int[] status = new int[1];
        boolean completed = onUiThread(activity, new Runnable() {
            @Override
            public void run() {
                status[0] = nativeMeasureOnUi(op, activity, outLong, outDouble);
            }
        });
        return completed ? status[0] : -1;
    }

    /* ── installation ──────────────────────────────────────────────────────── */

    /**
     * Names the provider the C half has just built, so the install can use it.
     *
     * <p>The provider is created by the C half rather than here because creating
     * a Java object is ordinary JNI work, and doing it before the hop keeps the
     * posted runnable to nothing but view work.
     */
    static void stageForInstall(NoguiAccessibilityProvider provider) {
        pending = provider;
    }

    /**
     * Finds the one view SDL renders into.
     *
     * <p>This has to be the real surface view rather than the decor view, for
     * two reasons that both show up on screen. A node's bounds are relative to
     * the window the app draws in, and {@code setBoundsInScreen} wants screen
     * coordinates, so the surface's own position on screen is the origin that
     * makes the two agree. And the framework attributes a virtual hierarchy to
     * the view whose provider it reads, so a provider on the decor view would
     * describe a hierarchy rooted somewhere the app is not drawing.
     *
     * <p>The walk uses only public API — {@code getChildAt}, {@code
     * getChildCount} — and matches on what SDL's view is rather than on a class
     * it might extend: a {@link SurfaceView}, or SDL's own view by name, so the
     * search survives SDL changing which one it uses. Every match is counted and
     * exactly one is required. A window with no such view, or with two, has no
     * single honest origin, and guessing between them would put every highlight
     * in the wrong place, so both are refusals.
     */
    private static View findHostView(View root, int[] matches) {
        if (root instanceof SurfaceView
                || "org.libsdl.app.SDLView".equals(root.getClass().getName())) {
            matches[0] += 1;
            return root;
        }
        if (!(root instanceof ViewGroup)) {
            return null;
        }
        ViewGroup group = (ViewGroup) root;
        View found = null;
        for (int index = 0; index < group.getChildCount(); index++) {
            View child = findHostView(group.getChildAt(index), matches);
            if (child != null && found == null) {
                found = child;
            }
        }
        return found;
    }

    /**
     * Installs the staged provider on the view SDL renders into and gives it the
     * bridge handle. Runs on the UI thread.
     *
     * <p>{@code View.setAccessibilityDelegate} is the supported way to hand a
     * view a virtual node provider when the view's own class cannot override
     * {@code getAccessibilityNodeProvider()}. Installing a delegate rather than a
     * subclass leaves the window's real view tree exactly as it was.
     *
     * <p>The delegate the view already carried is kept, so
     * {@link #uninstallOnUi} can put it back. A view with accessibility behaviour
     * of its own therefore gets it back rather than losing it to this bridge.
     *
     * <p>The view it landed on, and the provider on it, are published in static
     * fields so the C half can name the same view when it takes the bridge down.
     * Those fields are written and read only while the C half holds its own lock,
     * so the two halves cannot read different views.
     */
    private static int installOnUi(long handle, Activity activity) {
        NoguiAccessibilityProvider provider = pending;
        pending = null;
        if (provider == null) {
            return -3;
        }
        View decor = activity.getWindow().getDecorView();
        if (decor == null) {
            return -3;
        }
        int[] matches = new int[1];
        View host = findHostView(decor, matches);
        if (host == null || matches[0] != 1) {
            /* No surface to root the hierarchy on, or more than one and no way to
             * choose between them. Either way the origin a screen reader would
             * use is unknown, and an unknown origin is not worth a highlight in
             * the wrong place. */
            return -3;
        }
        provider.host = host;
        provider.previous = host.getAccessibilityDelegate();
        provider.bridge = handle;
        host.setAccessibilityDelegate(new View.AccessibilityDelegate() {
            @Override
            public AccessibilityNodeProvider getAccessibilityNodeProvider(View view) {
                return provider;
            }
        });
        s_installedProvider = provider;
        s_installedHost = host;
        return 0;
    }

    /** The view the last successful install put a provider on, or null. */
    static View installedHost() {
        return s_installedHost;
    }

    /**
     * Where the installed host sits on screen, in physical pixels.
     *
     * <p>Read with {@code getLocationOnScreen}, which is public API and a real
     * measurement. Assuming the decor view sits at the screen origin would be
     * wrong on any window with a status bar, a cutout or a system bar, and the
     * error is a whole offset applied to every node rather than a rounding
     * difference.
     */
    static int[] hostOrigin() {
        View host = s_installedHost;
        if (host == null) {
            return null;
        }
        int[] point = new int[2];
        host.getLocationOnScreen(point);
        return point;
    }

    /**
     * Takes the provider back off its host and clears its handle. Runs on the UI
     * thread.
     *
     * <p>The handle is cleared before the delegate is restored, so a framework
     * call arriving between the two finds zero and answers "no node" rather than
     * reaching storage the C half is about to release.
     */
    private static void uninstallOnUi(View host) {
        NoguiAccessibilityProvider provider = s_installedProvider;
        s_installedProvider = null;
        s_installedHost = null;
        if (provider == null) {
            return;
        }
        provider.bridge = 0L;
        if (host != null) {
            host.setAccessibilityDelegate(provider.previous);
        }
        provider.host = null;
        provider.previous = null;
    }

    /**
     * Installs the staged provider on the UI thread and waits for it.
     *
     * <p>Called by the C half, from SDL's native thread, which is not the UI
     * thread. Returns 0 once the provider is installed, and a refusal otherwise.
     */
    static int installOnUiThread(Activity activity, long handle) {
        final int[] status = new int[1];
        boolean completed = onUiThread(activity, new Runnable() {
            @Override
            public void run() {
                status[0] = installOnUi(handle, activity);
            }
        });
        return completed ? status[0] : -1;
    }

    /**
     * Takes the bridge back off its host view and clears its handle, on the UI
     * thread, without waiting.
     *
     * <p>Called by the C half during teardown, which is not on the UI thread and
     * must not pretend otherwise. The handle is cleared before the delegate is
     * removed, so a framework call arriving between the two finds zero and
     * answers "no node" rather than reaching storage the C half is about to
     * release. Restoring the previous delegate is the exact inverse of the
     * install.
     *
     * <p>This does not wait, and does not need to: the work touches only Java
     * objects, so a hop that lands after the C half has released its own storage
     * is still correct. Waiting here would mean a teardown could block on a busy
     * UI thread, which is the one moment blocking is least welcome.
     */
    static void uninstallOnUiThread(final Activity activity, final View host) {
        if (host == null) {
            return;
        }
        if (activity == null) {
            uninstallOnUi(host);
            return;
        }
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                uninstallOnUi(host);
            }
        });
    }

    /**
     * Tells the framework this window's content changed, on the UI thread.
     *
     * <p>A window that does not hear this keeps announcing the previous tree,
     * which is the difference between a screen reader that follows the app and
     * one that describes a screen the app has left. The event is the platform's
     * own TYPE_WINDOW_CONTENT_CHANGED and it is sent from the host view, because
     * that is the object the framework attributes a change to.
     *
     * <p>The event id is passed in rather than named here, so it is the value
     * the running framework actually publishes rather than one written into this
     * file and hoped for.
     */
    static void postContentChanged(Activity activity, final View host, final int eventType) {
        if (host == null || eventType == 0) {
            return;
        }
        if (activity == null) {
            host.sendAccessibilityEvent(eventType);
            return;
        }
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                host.sendAccessibilityEvent(eventType);
            }
        });
    }

    /* ── the framework's calls ─────────────────────────────────────────────── */

    /**
     * The framework's entry point for a virtual node.
     *
     * <p>A null return means "this id is not in the published tree", which is the
     * correct answer for a node the core has removed, for a stale id the
     * framework is still holding, and for a detached bridge. It is not a
     * failure: the framework treats a null node as absent, which is exactly what
     * a retired identity must look like.
     *
     * <p>{@link #HOST_VIEW_ID} is the framework's name for the host view itself.
     * The published root is what hangs under the host, so the host's node is
     * built from the root's facts. The C half attaches the root's children to it,
     * which is how the framework learns what to ask for next.
     */
    @Override
    public AccessibilityNodeInfo createAccessibilityNodeInfo(int virtualViewId) {
        long handle = this.bridge;
        if (handle == 0L) {
            return null;
        }
        if (virtualViewId == HOST_VIEW_ID) {
            int root = nativeRootId(handle);
            return root == 0 ? null : nativeCreateNode(handle, root);
        }
        if (virtualViewId < 0) {
            /* A negative id that is not HOST_VIEW_ID was never issued here.
             * Answering null keeps an arbitrary negative value from being taken
             * for an identity. */
            return null;
        }
        return nativeCreateNode(handle, virtualViewId);
    }

    /**
     * The framework asks for this when it wants the node that holds a focus.
     *
     * <p>The core's own focused node is the answer; nothing here invents one. No
     * focus, a detached bridge and a core that published no focus all produce
     * null, and the framework then starts from the root, which is the platform's
     * own meaning for "no focused node".
     */
    @Override
    public AccessibilityNodeInfo findFocus(int focus) {
        long handle = this.bridge;
        if (handle == 0L) {
            return null;
        }
        if (focus != AccessibilityNodeInfo.FOCUS_ACCESSIBILITY
                && focus != AccessibilityNodeInfo.FOCUS_INPUT) {
            /* The framework states which kind of focus it wants. A third value
             * is not a question this provider can answer, and answering with one
             * focus kind when the other was asked would be a different answer. */
            return null;
        }
        int focused = nativeFocusedId(handle);
        return focused == 0 ? null : nativeCreateNode(handle, focused);
    }

    /**
     * A real framework action on a real node.
     *
     * <p>The payload-carrying actions are read from the framework's own bundle
     * here and handed to their own native entry points, because their payloads
     * are structured data rather than an id: the text, the selection and the
     * progress value. Everything else is an id, and an id the C half does not
     * recognise, or one the core published no action for, is refused there. A
     * framework that asks for something the model cannot do gets false, which
     * the platform reports to the user as "that control cannot do that" — the
     * honest answer, rather than a default branch that claims success.
     *
     * <p>{@code action} is passed through unmasked. An action id is the whole
     * identity of a framework action, high bits included, because a named action
     * the app published is carried in those high bits; masking would collapse
     * distinct actions onto one another.
     */
    @Override
    public boolean performAction(int virtualViewId, int action, Bundle arguments) {
        long handle = this.bridge;
        if (handle == 0L || virtualViewId < 0) {
            return false;
        }
        if (action == AccessibilityNodeInfo.ACTION_SET_TEXT) {
            CharSequence value = null;
            if (arguments != null) {
                value = arguments.getCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE);
            }
            if (value == null) {
                /* The framework sent the action without the text it is supposed
                 * to carry. Forwarding it would edit the model with nothing. */
                return false;
            }
            return nativeSetText(handle, virtualViewId, value.toString());
        }
        if (action == AccessibilityNodeInfo.ACTION_SET_SELECTION) {
            int start = -1;
            int end = -1;
            if (arguments != null) {
                start = arguments.getInt(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1);
                end = arguments.getInt(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1);
            }
            if (start < 0 || end < 0) {
                return false;
            }
            return nativeSetSelection(handle, virtualViewId, start, end);
        }
        if (action == SET_PROGRESS_ID) {
            Float progress = null;
            if (arguments != null
                    && arguments.containsKey(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE)) {
                progress = arguments.getFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE);
            }
            if (progress == null) {
                /* The framework sent the action without the value it is
                 * supposed to carry. Forwarding it would tell the model the
                 * control jumped somewhere nobody asked for. */
                return false;
            }
            return nativeSetValue(handle, virtualViewId, progress.floatValue());
        }
        /* A named action travels under a platform id the shim owns, in a range
         * that cannot collide with a framework action. The C half decodes it to
         * the app's own identifier; asking it first is what keeps that range's
         * knowledge in one place instead of restating the numbering here. */
        int slot = nativeCustomActionSlot(handle, virtualViewId, action);
        if (slot >= 0) {
            return nativePerformCustomAction(handle, virtualViewId, action);
        }
        return nativePerformAction(handle, virtualViewId, action);
    }

    /**
     * Forwards the platform's memory-pressure signal to the C half.
     *
     * <p>Called by the app's activity from
     * {@code ComponentCallbacks2.onTrimMemory}, because that callback is delivered
     * to the activity and nowhere else. The platform's own level is passed
     * through unmapped; the C half owns the mapping, so the level this bridge
     * publishes and the level Android states are converted in exactly one place.
     *
     * <p>SDL's activity does not call this. An app that wants real memory
     * pressure must call it from its own activity; an app that does not gets
     * {@code NOGUI_MOBILE_ANDROID_TRIM_NONE}, which is a truthful "no pressure
     * reported" rather than a fabricated reading.
     */
    public static void dispatchTrimMemory(int level) {
        nativeSetTrimMemory(level);
    }
}
