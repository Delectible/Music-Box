# jaudiotagger (tags): desktop-only image classes it never uses on Android.
-dontwarn java.awt.**
-dontwarn javax.imageio.**
-dontwarn javax.swing.**
-dontwarn javax.sound.**
-dontwarn org.jaudiotagger.**
-keep class org.jaudiotagger.** { *; }
