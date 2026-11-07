cmake_minimum_required(VERSION 3.22.1)
project(convolution_quest LANGUAGES C CXX)
set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
find_package(OpenXR REQUIRED)
add_library(native_app_glue STATIC ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)
target_include_directories(native_app_glue PUBLIC ${ANDROID_NDK}/sources/android/native_app_glue)
add_library(RAVEQuestCore SHARED IMPORTED)
set_target_properties(RAVEQuestCore PROPERTIES IMPORTED_NO_SONAME TRUE IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/arm64-v8a/libRAVEQuestCore.so)
add_library(quest_player SHARED player.cpp bridge.cpp)
target_link_libraries(quest_player native_app_glue RAVEQuestCore OpenXR::openxr_loader android log EGL GLESv3)
target_link_options(quest_player PRIVATE -u ANativeActivity_onCreate)
# Analysis: the coordinator's chunk store and the pairing maths, without the player.
set(CONTROLLER_BRIDGE ${CMAKE_CURRENT_SOURCE_DIR}/third_party/controller-bridge)
add_library(convolution_analysis SHARED
    analysis/analysis_track.cpp analysis/analysis_jni.cpp
    ${CONTROLLER_BRIDGE}/qcb_crypto.c ${CONTROLLER_BRIDGE}/third_party/monocypher/monocypher.c)
target_include_directories(convolution_analysis PRIVATE analysis ${CONTROLLER_BRIDGE})
target_link_libraries(convolution_analysis z log)
