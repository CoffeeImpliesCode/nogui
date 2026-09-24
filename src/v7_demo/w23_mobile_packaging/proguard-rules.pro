# R8 / ProGuard rules for the W23 mobile run.
#
# These are SOURCE fixture rules, not a build input of this repository: nothing
# here is applied by `zig build`, and no dex is produced here. A consumer's
# release build applies them (AGP picks `proguard-rules.pro` up from the module
# by default).
#
# Every rule below exists because the name it keeps is resolved at RUN time
# rather than by the compiler, so a shrinker sees an unused class and removes it.
# That failure mode is silent in a debug build and total in a release one: the
# JNI call finds no class, the C half clears the exception, and the bridge simply
# reports "no screen reader" for an app that has one.
#
# The C half does its own JNI lookup by mangled name too, so these are the two
# halves of one contract: the class must exist under this exact package, and the
# native methods must keep these exact names. A rename on either side is a link
# error at the point of use, not a runtime no-op — except a shrinker removing
# one, which is precisely what these rules prevent.

# The provider: the C half resolves `org/libsdl/app/NoguiAccessibilityProvider`
# with FindClass and then every member on it, so nothing may be stripped or
# renamed. Keep all members rather than naming them, because a new field is a
# one-line change here and a silent release-only bug otherwise.
-keep class org.libsdl.app.NoguiAccessibilityProvider { *; }

# The consumer's activity: it is named from the manifest as a string, which no
# compiler ever reads, so it is exactly the kind of reference a shrinker drops.
-keep class org.libsdl.app.NoguiMobileActivity { *; }

# The native methods, by signature. The JNI short name (`nativeSetTrimMemory`)
# is what the Java side calls and the mangled long name is what the C half
# exports; keeping the declared natives preserves both, because R8 rewrites a
# call to a native consistently with the definition it keeps.
-keepclasseswithmembernames,includedescriptorclasses class org.libsdl.app.NoguiAccessibilityProvider {
    native <methods>;
}

# The framework's own types the shim resolves reflectively by name from C. R8
# does not rewrite framework references in a library it does not process, so these
# are listed only to document the dependency the C half has on them; keeping them
# costs nothing and makes a stripped-framework build fail loudly at JNI lookup
# rather than quietly at read time.
-keep class android.view.accessibility.AccessibilityNodeInfo { *; }
-keep class android.view.accessibility.AccessibilityNodeProvider { *; }

# No line numbers or source file names: neither is needed to diagnose this run,
# and both leak the consumer's source layout into the shipped artifact.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile