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

# WorkManager (daily yt-dlp update check) starts at app launch and opens its
# Room database by reflection; without these R8 strips what it needs and the
# app closes on start ("Failed to create an instance of ...WorkDatabase").
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class androidx.work.** { *; }
-keep class androidx.room.** { *; }
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
