#include <jni.h>
#include <string>
extern "C" char* rave_quest_call(const char*);
extern "C" void rave_quest_free(char*);
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_illixion_convolution_CoreBridge_callBytes(JNIEnv* env, jclass, jbyteArray input) {
    const auto size = env->GetArrayLength(input);
    if (size > 4 * 1024 * 1024) return nullptr;
    std::string request(static_cast<size_t>(size), '\0');
    env->GetByteArrayRegion(input, 0, size, reinterpret_cast<jbyte*>(request.data()));
    if (env->ExceptionCheck()) return nullptr;
    char* reply = rave_quest_call(request.c_str());
    if (!reply) return nullptr;
    std::string text(reply);
    rave_quest_free(reply);
    auto result = env->NewByteArray(static_cast<jsize>(text.size()));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(text.size()), reinterpret_cast<const jbyte*>(text.data()));
    return result;
}
