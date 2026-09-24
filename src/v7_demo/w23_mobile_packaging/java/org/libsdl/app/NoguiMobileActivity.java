package org.libsdl.app;

import android.content.ComponentCallbacks2;

/**
 * The consumer's activity for the W23 mobile run.
 *
 * <p>It exists for exactly one reason, and it is a reason no manifest entry can
 * express. {@code ComponentCallbacks2#onTrimMemory} is delivered to the
 * ACTIVITY and nowhere else in an Android application, and the memory-pressure
 * half of the E04 adapter reads that level from the C half this class reaches:
 * {@link NoguiAccessibilityProvider#dispatchTrimMemory(int)} hands the
 * platform's own level through unmapped, and the C half owns the mapping. An
 * activity that does not forward it reports no memory pressure at all, and a
 * missing signal is indistinguishable from a process that was never short of
 * memory.
 *
 * <p>The forward is AFTER {@code super}, so SDL's own handler runs first and the
 * level reaches both owners whatever order they run in. The level itself is
 * passed through by value and never mapped here: converting it in Java would put
 * the mapping in two places, and the two would disagree the first time Android
 * added a level.
 *
 * <p>Nothing else is overridden. The window, the surface, the input connection
 * and the whole lifecycle stay with SDL's own activity, because the E04 adapter
 * observes the window SDL made rather than one this class substitutes.
 */
public class NoguiMobileActivity extends SDLActivity {

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        NoguiAccessibilityProvider.dispatchTrimMemory(level);
    }

    /**
     * The framework calls this on some API levels through the callbacks
     * interface rather than the activity method, so both routes are covered. A
     * delivery through this one is forwarded with the level the framework
     * stated; the C half still owns the mapping.
     *
     * @param level one of {@link ComponentCallbacks2#TRIM_MEMORY_*} values.
     */
    @Override
    public void onLowMemory() {
        super.onLowMemory();
        NoguiAccessibilityProvider.dispatchTrimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE);
    }
}