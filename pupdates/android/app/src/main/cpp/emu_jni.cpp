// JNI glue for com.pupdates.app.Native
#include <jni.h>

#include <cstdlib>
#include <cstring>

#include "emu_core.h"

namespace {
struct Bytes {
    JNIEnv *env;
    jbyteArray arr;
    jbyte *ptr = nullptr;
    jsize len = 0;
    Bytes(JNIEnv *e, jbyteArray a) : env(e), arr(a) {
        if (a) { len = e->GetArrayLength(a); ptr = e->GetByteArrayElements(a, nullptr); }
    }
    ~Bytes() { if (ptr) env->ReleaseByteArrayElements(arr, ptr, JNI_ABORT); }
    const char *c() const { return reinterpret_cast<const char *>(ptr); }
};

jstring errOrNull(JNIEnv *env, int ok, const char *err) { return ok ? nullptr : env->NewStringUTF(err); }
}  // namespace

extern "C" {

JNIEXPORT jstring JNICALL Java_com_pupdates_app_Native_luaOpen(JNIEnv *env, jclass, jint kind, jbyteArray src, jbyteArray rom,
                                                              jbyteArray bios, jbyteArray save) {
    Bytes s(env, src), r(env, rom), b(env, bios), v(env, save);
    char err[512] = {0};
    int ok = lemu_open(kind, s.c(), size_t(s.len), r.c(), size_t(r.len), b.c(), size_t(b.len), v.c(), size_t(v.len), err, sizeof(err));
    return errOrNull(env, ok, err);
}

JNIEXPORT jint JNICALL Java_com_pupdates_app_Native_luaSize(JNIEnv *, jclass) { return (lemu_width() << 16) | lemu_height(); }

JNIEXPORT jstring JNICALL Java_com_pupdates_app_Native_luaFrame(JNIEnv *env, jclass, jobject out, jboolean draw) {
    auto *px = static_cast<uint8_t *>(env->GetDirectBufferAddress(out));
    jlong cap = env->GetDirectBufferCapacity(out);
    if (!px || cap < jlong(lemu_width()) * lemu_height() * 4) return env->NewStringUTF("the frame buffer is too small");
    char err[512] = {0};
    return errOrNull(env, lemu_frame(px, draw ? 1 : 0, err, sizeof(err)), err);
}

JNIEXPORT void JNICALL Java_com_pupdates_app_Native_luaKeys(JNIEnv *, jclass, jint mask) { lemu_keys(mask); }

JNIEXPORT jint JNICALL Java_com_pupdates_app_Native_luaAudio(JNIEnv *env, jclass, jshortArray out) {
    jsize max = env->GetArrayLength(out);
    jshort *p = env->GetShortArrayElements(out, nullptr);
    int n = lemu_audio(reinterpret_cast<int16_t *>(p), max);
    env->ReleaseShortArrayElements(out, p, 0);
    return n;
}

JNIEXPORT jbyteArray JNICALL Java_com_pupdates_app_Native_luaSave(JNIEnv *env, jclass) {
    uint8_t *data = nullptr;
    size_t len = lemu_save(&data);
    if (!len) return nullptr;
    jbyteArray arr = env->NewByteArray(jsize(len));
    env->SetByteArrayRegion(arr, 0, jsize(len), reinterpret_cast<jbyte *>(data));
    free(data);
    return arr;
}

JNIEXPORT void JNICALL Java_com_pupdates_app_Native_luaClose(JNIEnv *, jclass) { lemu_close(); }

JNIEXPORT jstring JNICALL Java_com_pupdates_app_Native_doomOpen(JNIEnv *env, jclass, jstring wad, jstring dir) {
    const char *w = env->GetStringUTFChars(wad, nullptr);
    const char *d = env->GetStringUTFChars(dir, nullptr);
    char err[512] = {0};
    int ok = doom_open(w, d, err, sizeof(err));
    env->ReleaseStringUTFChars(wad, w);
    env->ReleaseStringUTFChars(dir, d);
    return errOrNull(env, ok, err);
}

JNIEXPORT jint JNICALL Java_com_pupdates_app_Native_doomTick(JNIEnv *env, jclass, jobject out) {
    auto *px = static_cast<uint8_t *>(env->GetDirectBufferAddress(out));
    if (!px || env->GetDirectBufferCapacity(out) < 320 * 200 * 4) return -1;
    return doom_tick(px);
}

JNIEXPORT void JNICALL Java_com_pupdates_app_Native_doomKey(JNIEnv *, jclass, jboolean down, jint code) { doom_key(down ? 1 : 0, code); }

JNIEXPORT jint JNICALL Java_com_pupdates_app_Native_doomAudio(JNIEnv *env, jclass, jshortArray out) {
    jsize n = env->GetArrayLength(out) / 2;
    jshort *p = env->GetShortArrayElements(out, nullptr);
    int r = doom_audio(reinterpret_cast<int16_t *>(p), n);
    env->ReleaseShortArrayElements(out, p, 0);
    return r;
}

JNIEXPORT jstring JNICALL Java_com_pupdates_app_Native_doomError(JNIEnv *env, jclass) { return env->NewStringUTF(doom_error()); }

}  // extern "C"
