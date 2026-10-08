#include <jni.h>
#include <android/log.h>
#include <android_native_app_glue.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#define XR_USE_PLATFORM_ANDROID
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "ConvolutionXR", __VA_ARGS__)
static std::atomic<float> pictureAspect{16.f/9.f};
static std::atomic<int> packing{0}; // mono, half SBS, full SBS, half OU, full OU
static std::atomic<int> pictureWidth{1920}, pictureHeight{1080};
static std::atomic<bool> pictureReady{false};
extern "C" JNIEXPORT void JNICALL Java_com_illixion_convolution_PlayerActivity_setPicture(JNIEnv*, jclass, jfloat aspect, jint layout, jboolean ready, jint width, jint height) {
    if (std::isfinite(aspect) && aspect > 0) pictureAspect = aspect;
    if (width > 0 && height > 0) { pictureWidth = width; pictureHeight = height; }
    packing = layout;
    pictureReady = ready;
}

static void check(XrResult result, const char* operation) {
    if (XR_FAILED(result)) { LOG("%s failed: %d", operation, result); throw std::runtime_error(operation); }
}
struct Player {
    android_app* app;
    JNIEnv* env = nullptr;
    jclass activityClass = nullptr;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface pbuffer = EGL_NO_SURFACE;
    EGLConfig config{};
    XrInstance instance = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    XrSpace space = XR_NULL_HANDLE, viewSpace = XR_NULL_HANDLE;
    XrSwapchain video = XR_NULL_HANDLE, captions = XR_NULL_HANDLE;
    XrActionSet actions = XR_NULL_HANDLE;
    XrAction pause = XR_NULL_HANDLE, back = XR_NULL_HANDLE, recenter = XR_NULL_HANDLE, seek = XR_NULL_HANDLE;
    bool running = false, exit = false, active = false, centered = false;
    int width = 1920, height = 1080;
    XrPosef screenPose{{0,0,0,1}, {0,0,-3}};

    explicit Player(android_app* a): app(a) {}
    void java(const char* name, const char* signature = "()V") {
        auto method = env->GetMethodID(activityClass, name, signature);
        if (method) env->CallVoidMethod(app->activity->clazz, method);
        if (env->ExceptionCheck()) { env->ExceptionClear(); LOG("Java operation %s failed", name); exit = true; }
    }
    void init() {
        pictureReady = false;
        checkJava(app->activity->vm->AttachCurrentThread(&env, nullptr));
        activityClass = env->GetObjectClass(app->activity->clazz);
        auto getWidth = env->GetMethodID(activityClass, "videoWidth", "()I");
        auto getHeight = env->GetMethodID(activityClass, "videoHeight", "()I");
        width = env->CallIntMethod(app->activity->clazz, getWidth);
        height = env->CallIntMethod(app->activity->clazz, getHeight);
        if (width < 1 || height < 1 || width > 8192 || height > 8192) throw std::runtime_error("video dimensions");
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (!eglInitialize(display, nullptr, nullptr)) throw std::runtime_error("EGL initialize");
        const EGLint attributes[] = {EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
        EGLint count = 0;
        if (!eglChooseConfig(display, attributes, &config, 1, &count) || count == 0) throw std::runtime_error("EGL config");
        const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
        context = eglCreateContext(display,config,EGL_NO_CONTEXT,ctx);
        const EGLint surf[] = {EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
        pbuffer = eglCreatePbufferSurface(display,config,surf);
        if (context == EGL_NO_CONTEXT || pbuffer == EGL_NO_SURFACE || !eglMakeCurrent(display,pbuffer,pbuffer,context)) throw std::runtime_error("EGL context");
        PFN_xrInitializeLoaderKHR loader = nullptr;
        check(xrGetInstanceProcAddr(XR_NULL_HANDLE,"xrInitializeLoaderKHR",reinterpret_cast<PFN_xrVoidFunction*>(&loader)),"loader lookup");
        XrLoaderInitInfoAndroidKHR loaderInfo{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
        loaderInfo.applicationVM = app->activity->vm; loaderInfo.applicationContext = app->activity->clazz;
        check(loader(reinterpret_cast<XrLoaderInitInfoBaseHeaderKHR*>(&loaderInfo)),"loader initialize");
        const char* extensions[] = {XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME,XR_KHR_ANDROID_SURFACE_SWAPCHAIN_EXTENSION_NAME,XR_FB_COMPOSITION_LAYER_IMAGE_LAYOUT_EXTENSION_NAME};
        uint32_t n = 0; check(xrEnumerateInstanceExtensionProperties(nullptr,0,&n,nullptr),"enumerate extensions");
        std::vector<XrExtensionProperties> available(n,{XR_TYPE_EXTENSION_PROPERTIES});
        check(xrEnumerateInstanceExtensionProperties(nullptr,n,&n,available.data()),"read extensions");
        for (auto required: extensions) {
            bool found = false;
            for (const auto& p: available) if (!strcmp(required,p.extensionName)) found = true;
            if (!found) throw std::runtime_error(required);
        }
        XrInstanceCreateInfoAndroidKHR androidInfo{XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR};
        androidInfo.applicationVM = app->activity->vm; androidInfo.applicationActivity = app->activity->clazz;
        XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO}; info.next = &androidInfo;
        // Meta gates image-layout semantics on the application's API version.
        strcpy(info.applicationInfo.applicationName,"Convolution"); info.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,34);
        info.enabledExtensionCount = 4; info.enabledExtensionNames = extensions;
        check(xrCreateInstance(&info,&instance),"create instance");
        XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO}; systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        XrSystemId system; check(xrGetSystem(instance,&systemInfo,&system),"get system");
        PFN_xrGetOpenGLESGraphicsRequirementsKHR requirements;
        check(xrGetInstanceProcAddr(instance,"xrGetOpenGLESGraphicsRequirementsKHR",reinterpret_cast<PFN_xrVoidFunction*>(&requirements)),"graphics requirements lookup");
        XrGraphicsRequirementsOpenGLESKHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR}; check(requirements(instance,system,&req),"graphics requirements");
        XrGraphicsBindingOpenGLESAndroidKHR binding{XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
        binding.display = display; binding.config = config; binding.context = context;
        XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; sessionInfo.next = &binding; sessionInfo.systemId = system;
        check(xrCreateSession(instance,&sessionInfo,&session),"create session");
        XrReferenceSpaceCreateInfo reference{XR_TYPE_REFERENCE_SPACE_CREATE_INFO}; reference.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL; reference.poseInReferenceSpace.orientation.w = 1;
        check(xrCreateReferenceSpace(session,&reference,&space),"local space");
        reference.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        check(xrCreateReferenceSpace(session,&reference,&viewSpace),"view space");
        makeActions();
        PFN_xrCreateSwapchainAndroidSurfaceKHR createSurface;
        check(xrGetInstanceProcAddr(instance,"xrCreateSwapchainAndroidSurfaceKHR",reinterpret_cast<PFN_xrVoidFunction*>(&createSurface)),"surface extension lookup");
        XrSwapchainCreateInfo swap{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        swap.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
        swap.width = width; swap.height = height; // Surface producers choose format and buffer count.
        jobject videoSurface = nullptr, captionSurface = nullptr;
        check(createSurface(session,&swap,&video,&videoSurface),"video surface");
        swap.width = 1280; swap.height = 720;
        check(createSurface(session,&swap,&captions,&captionSurface),"subtitle surface");
        auto method = env->GetMethodID(activityClass,"startVideo","(Landroid/view/Surface;Landroid/view/Surface;)V");
        env->CallVoidMethod(app->activity->clazz,method,videoSurface,captionSurface);
        // Meta returns global JNI Surface references, owned by the swapchains.
        // Do not DeleteLocalRef them (CheckJNI aborts on that ownership mismatch).
        if (env->ExceptionCheck()) { env->ExceptionClear(); throw std::runtime_error("start decoder"); }
        LOG("surface_swapchain ready %dx%d; decoder writes directly to compositor",width,height);
    }
    static void checkJava(jint result) { if (result != JNI_OK) throw std::runtime_error("attach JVM"); }
    void makeActions() {
        XrActionSetCreateInfo set{XR_TYPE_ACTION_SET_CREATE_INFO}; strcpy(set.actionSetName,"transport"); strcpy(set.localizedActionSetName,"Playback");
        check(xrCreateActionSet(instance,&set,&actions),"action set");
        auto action = [&](const char* name, XrActionType type, XrAction& result) {
            XrActionCreateInfo a{XR_TYPE_ACTION_CREATE_INFO}; a.actionType = type; strcpy(a.actionName,name); strcpy(a.localizedActionName,name);
            check(xrCreateAction(actions,&a,&result),"action");
        };
        action("pause",XR_ACTION_TYPE_BOOLEAN_INPUT,pause); action("back",XR_ACTION_TYPE_BOOLEAN_INPUT,back);
        action("recenter",XR_ACTION_TYPE_BOOLEAN_INPUT,recenter); action("seek",XR_ACTION_TYPE_VECTOR2F_INPUT,seek);
        auto path = [&](const char* text) { XrPath p; check(xrStringToPath(instance,text,&p),"action path"); return p; };
        XrActionSuggestedBinding bindings[] = {{pause,path("/user/hand/right/input/a/click")},{back,path("/user/hand/right/input/b/click")},
            {recenter,path("/user/hand/left/input/x/click")},{seek,path("/user/hand/right/input/thumbstick")}};
        XrInteractionProfileSuggestedBinding suggested{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING}; suggested.interactionProfile = path("/interaction_profiles/oculus/touch_controller");
        suggested.countSuggestedBindings = 4; suggested.suggestedBindings = bindings;
        check(xrSuggestInteractionProfileBindings(instance,&suggested),"controller bindings");
        XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO}; attach.countActionSets = 1; attach.actionSets = &actions;
        check(xrAttachSessionActionSets(session,&attach),"attach actions");
    }
    bool pressed(XrAction action) {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = action;
        XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
        check(xrGetActionStateBoolean(session,&get,&value),"button state");
        return value.isActive && value.changedSinceLastSync && value.currentState;
    }
    void events() {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        while (xrPollEvent(instance,&event) == XR_SUCCESS) {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                auto state = reinterpret_cast<XrEventDataSessionStateChanged*>(&event)->state;
                LOG("session state %d",state);
                if (state == XR_SESSION_STATE_READY) {
                    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                    check(xrBeginSession(session,&begin),"begin session"); running = true;
                }
                if (state == XR_SESSION_STATE_STOPPING) { java("suspendVideo"); check(xrEndSession(session),"end session"); running = false; }
                if (state == XR_SESSION_STATE_EXITING || state == XR_SESSION_STATE_LOSS_PENDING) exit = true;
                bool visible = state == XR_SESSION_STATE_VISIBLE || state == XR_SESSION_STATE_FOCUSED;
                if (visible != active) { active = visible; java(visible ? "resumeVideo" : "suspendVideo"); }
            } else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) exit = true;
            else if (event.type == XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING) centered = false;
            event = {XR_TYPE_EVENT_DATA_BUFFER};
        }
    }
    void frame() {
        XrFrameWaitInfo wait{XR_TYPE_FRAME_WAIT_INFO}; XrFrameState state{XR_TYPE_FRAME_STATE}; check(xrWaitFrame(session,&wait,&state),"wait frame");
        XrFrameBeginInfo begin{XR_TYPE_FRAME_BEGIN_INFO}; check(xrBeginFrame(session,&begin),"begin frame");
        XrActiveActionSet activeSet{actions,XR_NULL_PATH};
        XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO}; sync.countActiveActionSets = 1; sync.activeActionSets = &activeSet;
        if (XR_SUCCEEDED(xrSyncActions(session,&sync))) {
            if (pressed(pause)) java("toggleVideo");
            if (pressed(back)) { java("leavePlayer"); exit = true; }
            if (pressed(recenter)) centered = false;
            XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = seek;
            XrActionStateVector2f stick{XR_TYPE_ACTION_STATE_VECTOR2F};
            if (XR_SUCCEEDED(xrGetActionStateVector2f(session,&get,&stick)) && stick.isActive && stick.changedSinceLastSync && std::abs(stick.currentState.x) > .7f) {
                auto method = env->GetMethodID(activityClass,"seekVideo","(I)V"); env->CallVoidMethod(app->activity->clazz,method,stick.currentState.x > 0 ? 10 : -10);
            }
        }
        if (!centered) {
            XrSpaceLocation head{XR_TYPE_SPACE_LOCATION};
            if (XR_SUCCEEDED(xrLocateSpace(viewSpace,space,state.predictedDisplayTime,&head)) &&
                (head.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) && (head.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT)) {
                const auto& q = head.pose.orientation;
                float yaw = std::atan2(2.f*(q.w*q.y+q.x*q.z),1.f-2.f*(q.y*q.y+q.z*q.z));
                screenPose.orientation = {0,std::sin(yaw*.5f),0,std::cos(yaw*.5f)};
                screenPose.position = {head.pose.position.x-3.f*std::sin(yaw),head.pose.position.y,head.pose.position.z-3.f*std::cos(yaw)};
                centered = true;
            }
        }
        const int layout = packing.load();
        const float aspect = pictureAspect.load();
        // Android producers can resize their buffers (e.g. after an HLS step).
        const int imageWidth = pictureWidth.load(), imageHeight = pictureHeight.load();
        XrCompositionLayerQuad quads[3]{};
        XrCompositionLayerImageLayoutFB imageLayout{XR_TYPE_COMPOSITION_LAYER_IMAGE_LAYOUT_FB};
        // Keep video and Canvas surfaces in the same Android producer convention.
        imageLayout.flags = XR_COMPOSITION_LAYER_IMAGE_LAYOUT_VERTICAL_FLIP_BIT_FB;
        const XrCompositionLayerBaseHeader* layers[3]{};
        int count = 0;
        if (state.shouldRender && pictureReady.load() && centered) {
            for (int eye = 0; eye < (layout ? 2 : 1); eye++) {
                auto& quad = quads[count]; quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD; quad.space = space;
                quad.next = &imageLayout;
                quad.eyeVisibility = layout ? (eye ? XR_EYE_VISIBILITY_RIGHT : XR_EYE_VISIBILITY_LEFT) : XR_EYE_VISIBILITY_BOTH;
                quad.subImage.swapchain = video; quad.subImage.imageRect = {{0,0},{imageWidth,imageHeight}};
                if (layout == 1 || layout == 2) { quad.subImage.imageRect.extent.width /= 2; quad.subImage.imageRect.offset.x = eye * (imageWidth/2); }
                if (layout == 3 || layout == 4) { quad.subImage.imageRect.extent.height /= 2; quad.subImage.imageRect.offset.y = eye * (imageHeight/2); }
                // Keep compositor filtering inside each packed eye. A half-texel
                // sample across the split can show a colored seam at its edge.
                if (layout && quad.subImage.imageRect.extent.width > 2 && quad.subImage.imageRect.extent.height > 2) {
                    quad.subImage.imageRect.offset.x++; quad.subImage.imageRect.offset.y++;
                    quad.subImage.imageRect.extent.width -= 2; quad.subImage.imageRect.extent.height -= 2;
                }
                quad.pose = screenPose;
                quad.size = {3.2f,3.2f/aspect};
                layers[count++] = reinterpret_cast<XrCompositionLayerBaseHeader*>(&quad);
            }
            auto& caption = quads[count]; caption.type = XR_TYPE_COMPOSITION_LAYER_QUAD; caption.space = space;
            caption.next = &imageLayout;
            caption.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
            caption.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
            caption.subImage.swapchain = captions; caption.subImage.imageRect = {{0,0},{1280,720}};
            caption.pose = screenPose; caption.pose.position.x += .015f*std::sin(2.f*std::atan2(screenPose.orientation.y,screenPose.orientation.w));
            caption.pose.position.z += .015f*std::cos(2.f*std::atan2(screenPose.orientation.y,screenPose.orientation.w));
            caption.size = {3.184f,3.184f/aspect};
            layers[count++] = reinterpret_cast<XrCompositionLayerBaseHeader*>(&caption);
        }
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime = state.predictedDisplayTime;
        end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE; end.layerCount = count; end.layers = layers;
        check(xrEndFrame(session,&end),"end frame");
    }
    ~Player() {
        if (env && activityClass) java("stopVideo");
        // The main looper must release the decoder before its output Surface is destroyed.
        if (captions) xrDestroySwapchain(captions);
        if (video) xrDestroySwapchain(video);
        if (viewSpace) xrDestroySpace(viewSpace);
        if (space) xrDestroySpace(space);
        if (session) xrDestroySession(session);
        if (actions) xrDestroyActionSet(actions);
        if (instance) xrDestroyInstance(instance);
        if (display != EGL_NO_DISPLAY) {
            eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
            if (pbuffer != EGL_NO_SURFACE) eglDestroySurface(display,pbuffer);
            if (context != EGL_NO_CONTEXT) eglDestroyContext(display,context);
            eglTerminate(display);
        }
        if (env) { if (activityClass) env->DeleteLocalRef(activityClass); app->activity->vm->DetachCurrentThread(); }
    }
};
void android_main(android_app* app) {
    LOG("android_main started");
    try {
        while (!app->destroyRequested && !app->window) {
            android_poll_source* source; int events;
            if (ALooper_pollOnce(100,nullptr,&events,reinterpret_cast<void**>(&source)) >= 0 && source) source->process(app,source);
        }
        if (app->destroyRequested) return;
        Player player(app); player.init();
        while (!app->destroyRequested && !player.exit) {
            android_poll_source* source; int events;
            while (ALooper_pollOnce(player.running ? 0 : 50,nullptr,&events,reinterpret_cast<void**>(&source)) >= 0) {
                if (source) source->process(app,source);
                if (app->destroyRequested) break;
            }
            player.events();
            if (player.running && !app->destroyRequested) player.frame();
        }
    } catch (const std::exception& e) { LOG("Player failed at %s",e.what()); }
    ANativeActivity_finish(app->activity);
}
