# jaudiotagger (tags): desktop-only image classes it never uses on Android.
-dontwarn java.awt.**
-dontwarn javax.imageio.**
-dontwarn javax.swing.**
-dontwarn javax.sound.**
-dontwarn org.jaudiotagger.**
-keep class org.jaudiotagger.** { *; }

# yt-dlp bridge (youtubedl-android): reflection / JSON mapping.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-dontwarn java.beans.**
-keep class org.apache.commons.** { *; }
-dontwarn org.apache.commons.**
