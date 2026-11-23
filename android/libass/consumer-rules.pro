# JNI exports bind by name (Java_com_ttai_ttplay_libass_*); keep the names stable.
-keepclasseswithmembernames class com.ttai.ttplay.libass.* {
    native <methods>;
}
