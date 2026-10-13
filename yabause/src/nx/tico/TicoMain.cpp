/// @file TicoMain.cpp
/// @brief Entry point for the tico build of YabaSanshiro: picks the renderer
/// (OpenGL through devkitPro's Mesa, or Vulkan through NVK), runs the emulator
/// and the tico overlay on top of either.
///
/// Copyright 2019 devMiyax(smiyaxdev@gmail.com)
/// Copyright 2025 tico
///
/// YabaSanshiro is free software; you can redistribute it and/or modify
/// it under the terms of the GNU General Public License as published by
/// the Free Software Foundation; either version 2 of the License, or
/// (at your option) any later version.

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include <SDL2/SDL.h>
#include <SDL_mixer.h>

#include <switch.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#endif
#include <GL/gl.h>
#include <GL/glext.h>

#include "nanovg.h"
#include "vulkan/Renderer.h"
#include "vulkan/VIDVulkan.h"

#include "TicoLogger.h"
#include "TicoSession.h"
#include "UsbStorage.h"
#include "YabaMenu.h"
#include "YabaRA.h"
#include "YabaSanshiroConfig.h"
#include "overlay/imgui_overlay.h"
#include "overlay/overlay_ui.h"
#include "overlay/tico_config.h"
#include "overlay/translation_manager.h"
#include "tico_entry.h"
#include "yaba_overlay_hook.h"

namespace ImGuiOverlay = SwitchFrontend::ImGuiOverlay;
namespace OverlayUI = SwitchFrontend::OverlayUI;
namespace TicoConfig = SwitchFrontend::TicoConfig;

//==============================================================================
// Yabause core
//==============================================================================

extern "C"
{
#include "cdbase.h"
#include "config.h"
#include "cs0.h"
#include "cs2.h"
#include "debug.h"
#include "m68kcore.h"
#include "memory.h"
#include "osdcore.h"
#include "peripheral.h"
#include "scsp.h"
#include "sh2core.h"
#include "sh2int.h"
#include "sndsdl.h"
#include "vdp2.h"
#include "vidogl.h"
#include "vidsoft.h"
#include "vulkan/VIDVulkanCInterface.h"
#include "yabause.h"
#include "ygl.h"
}

extern "C"
{
    u32 __NvOptimusEnablement = 1;
    u32 __NvDeveloperOption = 1;
    u32 __nx_applet_type = AppletType_Application;
    size_t __nx_heap_size = 0;

    YabaVkOverlayHook yaba_vk_overlay_hook = nullptr;
    YabaGlOverlayHook yaba_gl_overlay_hook = nullptr;

    M68K_struct *M68KCoreList[] = {
        &M68KDummy,
#ifdef HAVE_C68K
        &M68KC68K,
#endif
#ifdef HAVE_Q68
        &M68KQ68,
#endif
#ifdef HAVE_MUSASHI
        &M68KMusashi,
#endif
        NULL};

    SH2Interface_struct *SH2CoreList[] = {
        &SH2Interpreter,
        &SH2DebugInterpreter,
#if DYNAREC_DEVMIYAX
        &SH2Dyn,
        &SH2DynDebug,
#endif
        NULL};

    PerInterface_struct *PERCoreList[] = {
        &PERDummy,
        NULL};

    CDInterface *CDCoreList[] = {
        &DummyCD,
        &ISOCD,
        NULL};

    SoundInterface_struct *SNDCoreList[] = {
        &SNDSDL,
        NULL};

    // both renderers: the frontend picks one at launch (the renderer setting)
    VideoInterface_struct *VIDCoreList[] = {
        &VIDDummy,
        &VIDOGL,
        &CVIDVulkan,
        NULL};

#ifdef YAB_PORT_OSD
#include "nanovg/nanovg_osdcore.h"
    OSD_struct *OSDCoreList[] = {
        &OSDNnovgVulkan,
        &OSDNnovg,
        &OSDDummy,
        NULL};
#endif
}

//==============================================================================
// State
//==============================================================================

// Vulkan (NVK) or OpenGL, for this launch
static bool g_vulkan = false;

static YabaSanshiroConfig g_config;

// Emulator paths
static char biospath[256] = "";
static char cdpath[1024] = "";
static char buppath[1024] = "";
static char mpegpath[256] = "";
static char cartpath[1024] = "";
static int g_cartType = 0; // CART_* (cs0.h)
// asked of the player once the game has started (a missing cartridge dump)
static std::string g_startNotice;

// Screen: the OpenGL renderer draws 1920x1080 docked and the bottom-left
// 1280x720 handheld (the window is cropped); Vulkan's swapchain stays at the
// window's 1280x720 and the system scales it.
static int g_screenW = 1280;
static int g_screenH = 720;
static u8 g_lastOperationMode = 255;

// Emulator viewport (what VIDCore->Resize is given)
static int g_viewportX = 0;
static int g_viewportY = 0;
static int g_viewportW = 1280;
static int g_viewportH = 720;
static int g_engineAspectMode = 1; // ASPECT_RATE_MODE: ORIGINAL=0, 4:3=1, 16:9=2, FULL=3

// Pause: the menu is open, the emulator does not run
static bool g_paused = false;
static std::vector<uint8_t> g_pausedFrame; // RGBA, top row first
static int g_pausedFrameW = 0;
static int g_pausedFrameH = 0;

// FPS counter
static u64 g_fpsWindowStart = 0;
static int g_fpsFrames = 0;

static u64 NowMs()
{
    return armTicksToNs(armGetSystemTick()) / 1000000;
}

//==============================================================================
// Input
//==============================================================================

static const int MAX_PLAYERS = 2;

// per player: 0 = Saturn pad (digital), 1 = 3D controller (analog), 2 = light gun
static int g_padMode[MAX_PLAYERS] = {0, 0};
static void *g_padbits[MAX_PLAYERS] = {nullptr, nullptr};
static PadState g_pads[MAX_PLAYERS];
static int g_numPlayers = 1;
static HidSixAxisSensorHandle g_sixaxis[MAX_PLAYERS][4];
static PortData_struct *g_portData[MAX_PLAYERS] = {&PORTDATA1, &PORTDATA2};

#define MAKE_PAD(a, b) ((a << 24) | (b))

static void RegisterPadKeys(int player, void *padbits)
{
    PerSetKey(MAKE_PAD(player, PERPAD_UP), PERPAD_UP, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_RIGHT), PERPAD_RIGHT, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_DOWN), PERPAD_DOWN, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_LEFT), PERPAD_LEFT, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_START), PERPAD_START, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_A), PERPAD_A, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_B), PERPAD_B, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_C), PERPAD_C, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_X), PERPAD_X, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_Y), PERPAD_Y, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_Z), PERPAD_Z, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_RIGHT_TRIGGER), PERPAD_RIGHT_TRIGGER, padbits);
    PerSetKey(MAKE_PAD(player, PERPAD_LEFT_TRIGGER), PERPAD_LEFT_TRIGGER, padbits);
}

static void InitPeripherals()
{
    PerPortReset();
    for (int p = 0; p < g_numPlayers; p++)
    {
        if (g_padMode[p] == 2)
        {
            g_padbits[p] = (void *)PerGunAdd(g_portData[p]);
            PerSetKey(MAKE_PAD(p, PERGUN_TRIGGER), PERGUN_TRIGGER, g_padbits[p]);
            PerSetKey(MAKE_PAD(p, PERGUN_START), PERGUN_START, g_padbits[p]);
        }
        else if (g_padMode[p] == 1)
        {
            g_padbits[p] = (void *)Per3DPadAdd(g_portData[p]);
            RegisterPadKeys(p, g_padbits[p]);
        }
        else
        {
            g_padbits[p] = (void *)PerPadAdd(g_portData[p]);
            RegisterPadKeys(p, g_padbits[p]);
        }
    }
    LOG_INFO("INPUT", "Peripherals initialized for %d player(s)", g_numPlayers);
}

static void Key(int player, int key, bool down)
{
    if (down)
        PerKeyDown(MAKE_PAD(player, key));
    else
        PerKeyUp(MAKE_PAD(player, key));
}

static void HandleInput(int player, PadState *pad)
{
    const u64 held = padGetButtons(pad);
    void *padbits = g_padbits[player];

    Key(player, PERPAD_C, held & HidNpadButton_A);
    Key(player, PERPAD_B, held & HidNpadButton_B);
    Key(player, PERPAD_Y, held & HidNpadButton_X);
    Key(player, PERPAD_A, held & HidNpadButton_Y);
    Key(player, PERPAD_X, held & HidNpadButton_L);
    Key(player, PERPAD_Z, held & HidNpadButton_R);

    const HidAnalogStickState stick = padGetStickPos(pad, 0);
    if (g_padMode[player] == 1)
    {
        // 3D controller: the stick is analog, the d-pad digital
        PerAnalog_struct *analog = (PerAnalog_struct *)padbits;
        analog->analogbits[2] = (u8)((stick.x + 32768) >> 8);
        analog->analogbits[3] = (u8)((-stick.y + 32768) >> 8);
        Key(player, PERPAD_LEFT, held & HidNpadButton_Left);
        Key(player, PERPAD_RIGHT, held & HidNpadButton_Right);
        Key(player, PERPAD_UP, held & HidNpadButton_Up);
        Key(player, PERPAD_DOWN, held & HidNpadButton_Down);
    }
    else
    {
        // Saturn pad: the stick is a second d-pad
        Key(player, PERPAD_LEFT, (held & HidNpadButton_Left) || stick.x < -16384);
        Key(player, PERPAD_RIGHT, (held & HidNpadButton_Right) || stick.x > 16384);
        Key(player, PERPAD_UP, (held & HidNpadButton_Up) || stick.y > 16384);
        Key(player, PERPAD_DOWN, (held & HidNpadButton_Down) || stick.y < -16384);
    }

    if (g_padMode[player] == 2)
    {
        Key(player, PERGUN_TRIGGER, held & (HidNpadButton_ZR | HidNpadButton_ZL));
        Key(player, PERGUN_START, held & (HidNpadButton_Plus | HidNpadButton_Minus));

        // aim with the controller's gyro
        HidSixAxisSensorState sixaxis = {};
        const u64 style = padGetStyleSet(pad);
        if (style & HidNpadStyleTag_NpadHandheld)
            hidGetSixAxisSensorStates(g_sixaxis[player][0], &sixaxis, 1);
        else if (style & HidNpadStyleTag_NpadFullKey)
            hidGetSixAxisSensorStates(g_sixaxis[player][1], &sixaxis, 1);
        else if (style & HidNpadStyleTag_NpadJoyDual)
        {
            const u64 attributes = padGetAttributes(pad);
            if (attributes & HidNpadAttribute_IsRightConnected)
                hidGetSixAxisSensorStates(g_sixaxis[player][3], &sixaxis, 1);
            else if (attributes & HidNpadAttribute_IsLeftConnected)
                hidGetSixAxisSensorStates(g_sixaxis[player][2], &sixaxis, 1);
        }
        const float sensitivity = 150.0f;
        const s32 dx = (s32)(-sixaxis.angular_velocity.y * sensitivity);
        const s32 dy = (s32)(sixaxis.angular_velocity.x * sensitivity);
        if (dx != 0 || dy != 0)
            PerGunMove((PerGun_struct *)padbits, dx, dy);
        // a stick click recentres the aim
        if (held & (HidNpadButton_StickL | HidNpadButton_StickR))
        {
            PerGun_struct *gun = (PerGun_struct *)padbits;
            gun->gunbits[1] = 160 >> 8;
            gun->gunbits[2] = 160 & 0xFF;
            gun->gunbits[3] = 112 >> 8;
            gun->gunbits[4] = 112;
        }
    }
    else
    {
        Key(player, PERPAD_START, held & HidNpadButton_Plus);
        Key(player, PERPAD_RIGHT_TRIGGER, held & HidNpadButton_ZR);
        Key(player, PERPAD_LEFT_TRIGGER, held & HidNpadButton_ZL);
    }
}

static void InitControllers()
{
    padConfigureInput(MAX_PLAYERS, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&g_pads[0]);
    padInitialize(&g_pads[1], HidNpadIdType_No2);
    g_numPlayers = 1;
    g_padMode[0] = std::clamp(g_config.GetControllerMode(0), 0, 2);
    g_padMode[1] = std::clamp(g_config.GetControllerMode(1), 0, 1);

    for (int p = 0; p < MAX_PLAYERS; p++)
    {
        const HidNpadIdType id = p == 0 ? HidNpadIdType_No1 : HidNpadIdType_No2;
        hidGetSixAxisSensorHandles(&g_sixaxis[p][0], 1, p == 0 ? HidNpadIdType_Handheld : id,
                                   HidNpadStyleTag_NpadHandheld);
        hidGetSixAxisSensorHandles(&g_sixaxis[p][1], 1, id, HidNpadStyleTag_NpadFullKey);
        hidGetSixAxisSensorHandles(&g_sixaxis[p][2], 2, id, HidNpadStyleTag_NpadJoyDual);
        for (int i = 0; i < 4; i++)
            hidStartSixAxisSensor(g_sixaxis[p][i]);
    }
}

static void StopControllers()
{
    for (int p = 0; p < MAX_PLAYERS; p++)
        for (int i = 0; i < 4; i++)
            hidStopSixAxisSensor(g_sixaxis[p][i]);
}

// A second controller joins or leaves port 2.
static void UpdatePlayers()
{
    const bool second = padIsConnected(&g_pads[1]);
    if (second && g_numPlayers < 2)
    {
        g_numPlayers = 2;
        InitPeripherals();
    }
    else if (!second && g_numPlayers > 1)
    {
        g_numPlayers = 1;
        InitPeripherals();
    }
}

//==============================================================================
// OpenGL (EGL)
//==============================================================================

static EGLDisplay s_display = EGL_NO_DISPLAY;
static EGLContext s_context = EGL_NO_CONTEXT;
static EGLContext s_contextSub = EGL_NO_CONTEXT; // the rotation thread's (compute shaders)
static EGLSurface s_surface = EGL_NO_SURFACE;
static EGLSurface s_pbuffer = EGL_NO_SURFACE;

static bool InitEgl(NWindow *win)
{
    s_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!s_display)
        return false;
    eglInitialize(s_display, NULL, NULL);
    eglBindAPI(EGL_OPENGL_API);

    EGLConfig config;
    EGLint numConfigs = 0;
    static const EGLint fbAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE};
    eglChooseConfig(s_display, fbAttribs, &config, 1, &numConfigs);
    if (numConfigs == 0)
    {
        LOG_ERROR("EGL", "no EGL config: 0x%x", eglGetError());
        eglTerminate(s_display);
        s_display = EGL_NO_DISPLAY;
        return false;
    }
    s_surface = eglCreateWindowSurface(s_display, config, win, NULL);
    if (!s_surface)
    {
        LOG_ERROR("EGL", "surface creation failed: 0x%x", eglGetError());
        eglTerminate(s_display);
        s_display = EGL_NO_DISPLAY;
        return false;
    }
    static const EGLint ctxAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR, 4,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR,
        EGL_NONE};
    s_context = eglCreateContext(s_display, config, EGL_NO_CONTEXT, ctxAttribs);
    if (!s_context)
    {
        LOG_ERROR("EGL", "context creation failed: 0x%x", eglGetError());
        eglDestroySurface(s_display, s_surface);
        eglTerminate(s_display);
        s_surface = EGL_NO_SURFACE;
        s_display = EGL_NO_DISPLAY;
        return false;
    }
    // a context sharing the main one, for the rotation thread's compute shaders
    s_contextSub = eglCreateContext(s_display, config, s_context, ctxAttribs);
    if (s_contextSub)
    {
        const EGLint pbufferAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        s_pbuffer = eglCreatePbufferSurface(s_display, config, pbufferAttribs);
    }
    eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    eglSwapInterval(s_display, 1);
    LOG_INFO("EGL", "OpenGL %s | %s", glGetString(GL_VERSION), glGetString(GL_RENDERER));
    return true;
}

static void DeinitEgl()
{
    if (s_display == EGL_NO_DISPLAY)
        return;
    if (s_surface != EGL_NO_SURFACE && s_context != EGL_NO_CONTEXT &&
        eglGetCurrentContext() != s_context)
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    glFinish();
    eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (s_contextSub)
        eglDestroyContext(s_display, s_contextSub);
    if (s_pbuffer)
        eglDestroySurface(s_display, s_pbuffer);
    if (s_context)
        eglDestroyContext(s_display, s_context);
    if (s_surface)
        eglDestroySurface(s_display, s_surface);
    eglTerminate(s_display);
    s_contextSub = s_context = EGL_NO_CONTEXT;
    s_pbuffer = s_surface = EGL_NO_SURFACE;
    s_display = EGL_NO_DISPLAY;
}

// The main thread takes the context from the VDP thread (async rendering)
// while it draws on its own: paused, or changing the viewport.
static void GlBorrow()
{
    if (yabsys.UseAsyncRendering)
    {
        VdpRevoke();
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    }
}

static void GlGiveBack()
{
    glFinish();
    if (yabsys.UseAsyncRendering)
    {
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        VdpResume();
    }
}

//==============================================================================
// Vulkan (NVK)
//==============================================================================

extern "C" void nouveau_horizon_runtime_shutdown(void (*step)(const char *what));

static Renderer *s_renderer = nullptr;
static bool s_vulkanReady = false;

/// The instance and device, and the default window for VIDVulkan. Before
/// YabauseInit: VIDVulkanInit needs the renderer and window to exist.
static bool InitVulkan()
{
    s_renderer = new Renderer();
    s_renderer->setNativeWindow(nwindowGetDefault());
    VIDVulkan::getInstance()->setRenderer(s_renderer);
    if (s_renderer->GetVulkanDevice() == VK_NULL_HANDLE)
    {
        LOG_ERROR("VULKAN", "Vulkan device creation failed");
        return false;
    }
    const VkExtent2D extent = VIDVulkan::getInstance()->getSurfaceSize();
    LOG_INFO("VULKAN", "Vulkan ready: swapchain %ux%u", extent.width, extent.height);
    s_vulkanReady = true;
    return true;
}

/// After YabauseDeInit. Leaked GPU objects survive into the next chainloaded
/// NRO and corrupt its heap memory attributes, so everything goes.
static void DeinitVulkan()
{
    s_vulkanReady = false;
    delete s_renderer;
    s_renderer = nullptr;
    // Whatever the core leaked still references the driver, which keeps its
    // nvmap handles and the pages behind them: the homebrew loader then fails
    // to take the memory back (0xD401). Close the sessions regardless.
    nouveau_horizon_runtime_shutdown(nullptr);
}

// The overlay's view of the render pass the renderer has open.
static void VulkanOverlay(VkRenderPass renderPass, VkCommandBuffer commandBuffer)
{
    if (!yaba_vk_overlay_hook)
        return;
    VIDVulkan *vid = VIDVulkan::getInstance();
    const VkExtent2D extent = vid->getSurfaceSize();
    YabaVkOverlayContext context = {};
    context.instance = s_renderer->GetVulkanInstance();
    context.physical_device = vid->getPhysicalDevice();
    context.device = vid->getDevice();
    context.queue = vid->getVulkanQueue();
    context.queue_family = vid->getVulkanGraphicsQueueFamilyIndex();
    context.render_pass = renderPass;
    context.command_buffer = commandBuffer;
    context.format = VK_FORMAT_UNDEFINED;
    context.image_count = vid->getFrameBufferCount();
    context.width = extent.width;
    context.height = extent.height;
    yaba_vk_overlay_hook(&context);
}

//==============================================================================
// Yabause callbacks
//==============================================================================

extern "C"
{
    NVGcontext *getGlobalNanoVGContext() { return NULL; }
    void DrawDebugInfo() {}
    void YuiErrorMsg(const char *string) { LOG_ERROR("YUI", "%s", string); }

    const char *YuiGetShaderCachePath()
    {
        // callers append "<hash>.spv"
        return "sdmc:/tico/cache/saturn/";
    }

    void YuiSwapBuffers(void)
    {
        if (g_vulkan)
        {
            // VIDVulkan submitted the frame (the overlay drew inside it)
            if (s_vulkanReady)
                VIDVulkan::getInstance()->present();
            SetOSDToggle(0);
            return;
        }
        if (s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE)
            return;
        if (yaba_gl_overlay_hook)
        {
            glViewport(0, 0, g_screenW, g_screenH);
            yaba_gl_overlay_hook(g_screenW, g_screenH);
        }
        eglSwapBuffers(s_display, s_surface);
        // the new back buffer is undefined: clear it, so the letterbox stays black
        glViewport(0, 0, g_screenW, g_screenH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
        SetOSDToggle(0);
    }

    int YuiRevokeOGLOnThisThread()
    {
        if (g_vulkan || s_display == EGL_NO_DISPLAY)
            return 0;
        // the VDP thread hands the main context back and keeps the shared one,
        // which its rotation thread's compute shaders run on
        if (eglGetCurrentContext() == s_contextSub)
            return 0;
        if (s_contextSub != EGL_NO_CONTEXT &&
            (s_pbuffer != EGL_NO_SURFACE
                 ? eglMakeCurrent(s_display, s_pbuffer, s_pbuffer, s_contextSub)
                 : eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, s_contextSub)))
            return 0;
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        return 0;
    }

    // A thread that is ending must hold no context: EGL only destroys a
    // context or surface once nothing has it current, so whatever stayed
    // bound to a dead thread is never freed, and its GPU buffers outlive the
    // NRO (the homebrew loader then fails with 0xD401 on exit).
    void YuiReleaseOGLOnThisThread()
    {
        if (g_vulkan || s_display == EGL_NO_DISPLAY)
            return;
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }

    int YuiUseOGLOnThisThread()
    {
        if (g_vulkan || s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE)
            return 0;
        if (eglGetCurrentContext() != s_context)
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        return 0;
    }
}

//==============================================================================
// Display
//==============================================================================

// Saturn base resolution for integer scaling (the most common mode)
static constexpr int SATURN_BASE_W = 320;
static constexpr int SATURN_BASE_H = 224;

/// Display mode 0 = Integer (displaySize 4..7 = 1x..4x, 8 = Auto), 1 = Display
/// (displaySize 0 = Stretch, 1 = 4:3, 2 = 16:9, 3 = Original). With OpenGL the
/// main thread must hold the context.
static void ApplyDisplay(int displayMode, int displaySize)
{
    if (displayMode == 0)
    {
        int scale;
        if (displaySize == 8)
            scale = std::max(1, std::min(g_screenW / SATURN_BASE_W, g_screenH / SATURN_BASE_H));
        else
            scale = std::max(1, displaySize - 3);
        const int w = std::min(SATURN_BASE_W * scale, g_screenW);
        const int h = std::min(SATURN_BASE_H * scale, g_screenH);
        g_viewportX = (g_screenW - w) / 2;
        g_viewportY = (g_screenH - h) / 2;
        g_viewportW = w;
        g_viewportH = h;
        g_engineAspectMode = 0; // ORIGINAL: native pixels, centred
    }
    else
    {
        g_viewportX = 0;
        g_viewportY = 0;
        g_viewportW = g_screenW;
        g_viewportH = g_screenH;
        static const int kAspect[] = {3, 1, 2, 0}; // Stretch, 4:3, 16:9, Original
        g_engineAspectMode = displaySize >= 0 && displaySize <= 3 ? kAspect[displaySize] : 1;
    }
    if (g_vulkan)
    {
        // the Vulkan core fills the surface and letterboxes from the aspect mode
        VIDCore->Resize(0, 0, g_screenW, g_screenH, 1, g_engineAspectMode);
    }
    else
    {
        VIDCore->Resize(g_viewportX, g_viewportY, g_viewportW, g_viewportH, 1, g_engineAspectMode);
        glViewport(0, 0, g_screenW, g_screenH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
    }
    LOG_INFO("DISPLAY", "mode=%d size=%d viewport=%d,%d %dx%d aspect=%d", displayMode,
             displaySize, g_viewportX, g_viewportY, g_viewportW, g_viewportH, g_engineAspectMode);
}

// The display settings as the menu stores them.
static void ApplyDisplaySettings()
{
    const std::string mode = TicoConfig::GetConfigValue("display_mode", "Display");
    if (mode == "Integer")
    {
        const std::string scale = TicoConfig::GetConfigValue("integer_scale", "Auto");
        int size = 8;
        if (scale == "1x")
            size = 4;
        else if (scale == "2x")
            size = 5;
        else if (scale == "3x")
            size = 6;
        else if (scale == "4x")
            size = 7;
        ApplyDisplay(0, size);
    }
    else
    {
        const std::string size = TicoConfig::GetConfigValue("display_size", "4:3");
        ApplyDisplay(1, size == "Stretch" ? 0 : size == "16:9" ? 2 : size == "Original" ? 3 : 1);
    }
}

static void SetGlScreenForMode(u8 mode)
{
    if (mode == AppletOperationMode_Handheld)
    {
        // the 1080p window cropped to the bottom-left 1280x720 (GL's origin)
        nwindowSetCrop(nwindowGetDefault(), 0, 360, 1280, 1080);
        g_screenW = 1280;
        g_screenH = 720;
    }
    else
    {
        nwindowSetCrop(nwindowGetDefault(), 0, 0, 1920, 1080);
        g_screenW = 1920;
        g_screenH = 1080;
    }
}

// Handheld <-> docked. Only the OpenGL renderer changes size.
static void UpdateScreenMode()
{
    const u8 mode = appletGetOperationMode();
    if (mode == g_lastOperationMode)
        return;
    g_lastOperationMode = mode;
    if (g_vulkan)
        return;
    SetGlScreenForMode(mode);
    if (!g_paused)
        GlBorrow();
    ApplyDisplaySettings();
    if (!g_paused)
        GlGiveBack();
}

//==============================================================================
// Settings that apply while the game runs
//==============================================================================

// The controller each port has (Normal, 3D, LightGun), as the menu stores it.
static int ControllerMode(int player)
{
    const std::string mode = TicoConfig::GetConfigValue(
        player == 0 ? "controller_1_mode" : "controller_2_mode", "Normal");
    if (mode == "3D")
        return 1;
    // the light gun only plugs into port 1
    if (mode == "LightGun" && player == 0)
        return 2;
    return 0;
}

// Vulkan's VDP2 composite: Accurate (per-pixel) or Fast (the legacy path).
// The core reads it every frame, so it changes while the game runs.
static void ApplyVdp2Composite()
{
    if (!g_vulkan)
        return;
    const bool accurate = TicoConfig::GetConfigValue("vdp2_composite", "Accurate") != "Fast";
    VIDCore->SetSettingValue(VDP_SETTING_VDP2_NEW_COMPOSITE, accurate ? 1 : 0);
}

static void ApplyLiveSettings()
{
    ApplyVdp2Composite();
    // paused: the main thread holds the renderer
    ApplyDisplaySettings();

    // a new controller is plugged in right away, as the game would see it
    const int modes[MAX_PLAYERS] = {ControllerMode(0), ControllerMode(1)};
    if (modes[0] != g_padMode[0] || modes[1] != g_padMode[1])
    {
        g_padMode[0] = modes[0];
        g_padMode[1] = modes[1];
        InitPeripherals();
    }
    if (TicoConfig::GetConfigValue("frame_skip", "enabled") == "enabled")
        EnableAutoFrameSkip();
    else
        DisableAutoFrameSkip();
}

//==============================================================================
// Pause
//==============================================================================

// Reads back what is on screen, RGBA top row first.
static void CapturePausedFrame()
{
    g_pausedFrame.clear();
    g_pausedFrameW = g_pausedFrameH = 0;
    if (g_vulkan)
    {
        void *buffer = nullptr;
        int w = 0, h = 0;
        VIDVulkan::getInstance()->getScreenshot(&buffer, w, h);
        if (buffer && w > 0 && h > 0)
        {
            const uint8_t *pixels = static_cast<const uint8_t *>(buffer);
            g_pausedFrame.assign(pixels, pixels + static_cast<size_t>(w) * h * 4);
            g_pausedFrameW = w;
            g_pausedFrameH = h;
        }
        free(buffer);
        return;
    }
    const int w = g_screenW, h = g_screenH;
    std::vector<uint8_t> bottomUp(static_cast<size_t>(w) * h * 4);
    glReadBuffer(GL_FRONT);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, bottomUp.data());
    glReadBuffer(GL_BACK);
    g_pausedFrame.resize(bottomUp.size());
    const size_t row = static_cast<size_t>(w) * 4;
    for (int y = 0; y < h; y++)
        std::memcpy(g_pausedFrame.data() + y * row, bottomUp.data() + (h - 1 - y) * row, row);
    g_pausedFrameW = w;
    g_pausedFrameH = h;
}

static void Pause()
{
    if (g_paused)
        return;
    g_paused = true;
    if (g_vulkan)
    {
        // the VDP thread finishes its frame before the main thread presents
        if (yabsys.UseAsyncRendering)
            VdpRevoke();
    }
    else
    {
        GlBorrow();
    }
    CapturePausedFrame();
    // the menu draws over the frame, so it shows opaque
    for (size_t i = 3; i < g_pausedFrame.size(); i += 4)
        g_pausedFrame[i] = 0xFF;
    ImGuiOverlay::SetBackground(g_pausedFrame.data(), g_pausedFrameW, g_pausedFrameH);
    ScspMuteAudio(SCSP_MUTE_SYSTEM);
    SDL_PauseAudio(1);
}

static void Resume()
{
    if (!g_paused)
        return;
    g_paused = false;
    ImGuiOverlay::ClearBackground();
    if (g_vulkan)
    {
        if (yabsys.UseAsyncRendering)
            VdpResume();
    }
    else
    {
        GlGiveBack();
    }
    SDL_PauseAudio(0);
    ScspUnMuteAudio(SCSP_MUTE_SYSTEM);
}

// While paused: the paused frame and the menu, presented by the main thread.
static void PresentPaused()
{
    if (g_vulkan)
    {
        VIDVulkan::getInstance()->renderExternal(
            [](VkDevice, VkPhysicalDevice, VkRenderPass renderPass, VkCommandBuffer commandBuffer) {
                VulkanOverlay(renderPass, commandBuffer);
            });
        return;
    }
    glViewport(0, 0, g_screenW, g_screenH);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    if (yaba_gl_overlay_hook)
        yaba_gl_overlay_hook(g_screenW, g_screenH);
    eglSwapBuffers(s_display, s_surface);
    glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
}

//==============================================================================
// Emulator
//==============================================================================

static bool IsFile(const std::string &path)
{
    struct stat status;
    return stat(path.c_str(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size > 0;
}

/// The cartridge in the expansion slot, and the file it needs:
///   backup RAM  its contents, in the saves folder, shared by every game as a
///               real cartridge is (created on first use, written on exit)
///   Action Replay  the firmware dump, system/saturn/ar.bin
///   16 Mbit ROM    the game's cartridge dump, system/saturn/<game>.rom (or
///                  rom_cart.bin)
/// Without its dump a cartridge is left out, so the game still boots.
static void PrepareCartridge()
{
    g_cartType = g_config.GetCartridgeType();
    cartpath[0] = '\0';
    const std::string system = tico_system_dir();
    switch (g_cartType)
    {
    case CART_BACKUPRAM4MBIT:
    case CART_BACKUPRAM8MBIT:
    case CART_BACKUPRAM16MBIT:
    case CART_BACKUPRAM32MBIT:
    {
        static const int kMbit[] = {4, 8, 16, 32};
        std::snprintf(cartpath, sizeof(cartpath), "%sbackup_cart_%dmbit.bin", tico_saves_dir(),
                      kMbit[g_cartType - CART_BACKUPRAM4MBIT]);
        break;
    }
    case CART_PAR:
    case CART_ROM16MBIT:
    {
        std::vector<std::string> candidates;
        if (g_cartType == CART_PAR)
            candidates = {system + "ar.bin", system + "action_replay.bin"};
        else
            candidates = {system + tico_game_stem() + ".rom", system + "rom_cart.bin"};
        for (const std::string &candidate : candidates)
        {
            if (IsFile(candidate))
            {
                std::snprintf(cartpath, sizeof(cartpath), "%s", candidate.c_str());
                break;
            }
        }
        if (!cartpath[0])
        {
            LOG_WARN("EMU", "no dump for cartridge %d at %s", g_cartType, candidates[0].c_str());
            g_startNotice =
                (g_cartType == CART_PAR ? std::string("Action Replay") : std::string("ROM cartridge")) +
                ": no dump at " + candidates[0] + ". The game starts without the cartridge.";
            g_cartType = CART_NONE;
        }
        break;
    }
    case CART_NETLINK:
        // nothing on Switch to connect it to
        g_cartType = CART_NONE;
        break;
    default:
        break;
    }
    LOG_INFO("EMU", "cartridge %d (%s)", g_cartType, cartpath[0] ? cartpath : "no file");
}

static void PreparePaths()
{
    std::snprintf(cdpath, sizeof(cdpath), "%s", tico_disc_path());
    // the real BIOS when there is one, unless the game is set to the emulated one
    biospath[0] = '\0';
    if (TicoConfig::GetConfigValue("bios", "real") != "emulated")
    {
        if (const char *bios = tico_bios_path())
            std::snprintf(biospath, sizeof(biospath), "%s", bios);
    }

    // Backup RAM per game, shared by its discs: "(Disc N)" is left out
    std::string name = tico_game_stem();
    for (const char *marker : {"(Disc ", "(Disk ", "(CD"})
    {
        const size_t at = name.find(marker);
        if (at == std::string::npos)
            continue;
        const size_t close = name.find(')', at);
        if (close != std::string::npos)
            name.erase(at, close - at + 1);
        break;
    }
    while (!name.empty() && name.back() == ' ')
        name.pop_back();
    std::snprintf(buppath, sizeof(buppath), "%s%s.bup", tico_saves_dir(), name.c_str());
    LOG_INFO("EMU", "disc %s, backup %s, bios %s", cdpath, buppath,
             biospath[0] ? biospath : "(emulated)");
}

static int InitEmulator()
{
    yabauseinit_struct yinit = {};
    yinit.m68kcoretype = M68KCORE_MUSASHI;
    yinit.percoretype = PERCORE_DUMMY;
#if DYNAREC_DEVMIYAX
    yinit.sh2coretype = 3; // devmiyax dynarec
#else
    yinit.sh2coretype = SH2CORE_INTERPRETER;
#endif
    yinit.vidcoretype = g_vulkan ? VIDCORE_VULKAN : VIDCORE_OGL;
    yinit.sndcoretype = SNDCORE_SDL;
    yinit.cdcoretype = CDCORE_ISO;
    yinit.carttype = g_cartType;
    yinit.regionid = 0;
    yinit.biospath = biospath[0] ? biospath : NULL;
    yinit.cdpath = cdpath;
    yinit.buppath = buppath;
    yinit.mpegpath = mpegpath;
    yinit.cartpath = cartpath;
    yinit.videoformattype = g_config.GetVideoFormat();
    yinit.frameskip = g_config.GetFrameSkip();
    yinit.framelimit = g_config.GetFrameLimit();
    yinit.usethreads = 1;
    yinit.use_cpu_affinity = 1;
    yinit.skip_load = 0; // a test hook: with the emulated BIOS no game would load
    // straight into the game; the emulated BIOS always does
    yinit.use_quick_load =
        biospath[0] && TicoConfig::GetConfigValue("skip_bios_intro", "disabled") == "enabled";
    yinit.video_filter_type = g_config.GetVideoFilter();
    yinit.polygon_generation_mode = g_config.GetPolygonMode();
    yinit.use_new_scsp = 1;
    yinit.resolution_mode = g_config.GetResolutionMode();
    yinit.rotate_screen = g_config.GetRotateScreen();
    yinit.scsp_sync_count_per_frame = g_config.GetSCSPSync();
    yinit.extend_backup = 0;
    yinit.scsp_main_mode = 1;
    yinit.rbg_use_compute_shader = g_config.GetRBGComputeShader();
    yinit.rbg_resolution_mode = g_config.GetRBGResolutionMode();
    yinit.use_sh2_cache = g_config.GetSH2Cache();
    yinit.use_async_rendering = g_config.GetAsyncRendering();
    if (yinit.frameskip)
        EnableAutoFrameSkip();

    if (YabauseInit(&yinit) == -1)
    {
        LOG_ERROR("EMU", "YabauseInit failed");
        return -1;
    }
    LogStart();
    return 0;
}

//==============================================================================
// The game list (started without a game)
//==============================================================================

static void RunLibrary()
{
    YabaMenu::Init({}, true);
    YabaMenu::Open();
    while (appletMainLoop())
    {
        padUpdate(&g_pads[0]);
        YabaMenu::Update(padGetButtons(&g_pads[0]), padGetButtonsDown(&g_pads[0]));
        if (YabaMenu::TakeExitRequest())
            break;
        PresentPaused();
    }
    YabaMenu::Shutdown();
}

//==============================================================================
// Shutdown
//==============================================================================

/// After YabauseDeInit, which stops the VDP thread (with async rendering it
/// hands the GL context back as it goes): the main thread takes the context,
/// frees the overlay's GPU objects while the renderer still exists, then the
/// renderer, audio and services. Nothing may hold GPU memory, a thread or an
/// audio session when main returns: the homebrew loader unmaps the NRO then.
static void ShutdownFrontend()
{
    if (!g_vulkan && s_display != EGL_NO_DISPLAY && s_surface != EGL_NO_SURFACE &&
        eglGetCurrentContext() != s_context)
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    ImGuiOverlay::Shutdown();
    if (g_vulkan)
        DeinitVulkan();
    else
        DeinitEgl();

    StopControllers();
    Mix_CloseAudio();
    SDL_Quit();
    UsbStorage::Shutdown();
    socketExit();
    romfsExit();
}

//==============================================================================
// Main
//==============================================================================

int main(int argc, char **argv)
{
    LOG_INFO("HOME", "YabaSanshiro starting (argc=%d)", argc);

    if (R_FAILED(romfsInit()))
        LOG_WARN("HOME", "romfsInit failed");
    // RetroAchievements talks HTTP through curl
    socketInitializeDefault();
    UsbStorage::Init();

    // SDL audio for the core and the RetroAchievements sounds
    if (SDL_Init(SDL_INIT_AUDIO) < 0)
        LOG_ERROR("HOME", "SDL_Init(AUDIO) failed: %s", SDL_GetError());
    else if (Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 1024) < 0)
        LOG_ERROR("HOME", "Mix_OpenAudio failed: %s", Mix_GetError());

    // tico's settings, the launch arguments and the folders they name
    TicoConfig::ReloadConfig();
    SwitchFrontend::OverlayTranslation::TranslationManager::Instance().Init();
    tico_prepare(argc, argv);
    const bool library = tico_library_mode();
    if (!library)
        TicoConfig::SetGame(tico_rom_path());

    // the emulator's options: the module's, with this game's on top
    g_config.Load();
    TicoConfig::ApplyToCore([](const std::string &key, const std::string &value) {
        g_config.SetValue(key, value);
    });

    // the game list draws with OpenGL; a game uses the renderer setting
    g_vulkan = !library && TicoConfig::GetConfigValue("renderer", "gl") == "vulkan";
    LOG_INFO("HOME", "renderer: %s", g_vulkan ? "Vulkan (NVK)" : "OpenGL");

    appletLockExit();
    apmSetPerformanceConfiguration(ApmPerformanceMode_Normal, 0x92220007);
    apmSetPerformanceConfiguration(ApmPerformanceMode_Boost, 0x92220008);
    mkdir("sdmc:/tico/cache", 0777);
    mkdir("sdmc:/tico/cache/saturn", 0777);

    g_lastOperationMode = appletGetOperationMode();
    bool ready;
    if (g_vulkan)
    {
        g_screenW = 1280;
        g_screenH = 720;
        ready = InitVulkan();
    }
    else
    {
        // a 1080p window: docked uses all of it, handheld the cropped 720p
        nwindowSetDimensions(nwindowGetDefault(), 1920, 1080);
        SetGlScreenForMode(g_lastOperationMode);
        ready = InitEgl(nwindowGetDefault());
    }
    if (!ready)
    {
        LOG_ERROR("HOME", "renderer init failed");
        appletUnlockExit();
        return EXIT_FAILURE;
    }

    ImGuiOverlay::Init(g_vulkan);
    ImGuiOverlay::SetRAAlerts(YabaRA::AlertSource());
    OverlayUI::ReloadSettings();
    InitControllers();

    if (library)
    {
        RunLibrary();
        ShutdownFrontend();
        tico_queue_return();
        appletUnlockExit();
        return 0;
    }

    PreparePaths();
    PrepareCartridge();
    if (InitEmulator() == -1)
    {
        YabauseDeInit();
        ShutdownFrontend();
        tico_queue_return();
        appletUnlockExit();
        return EXIT_FAILURE;
    }
    InitPeripherals();

    // the overlay draws inside the Vulkan renderer's last render pass
    if (g_vulkan)
    {
        VIDVulkan::getInstance()->setOnOverlayRender(
            [](VkCommandBuffer commandBuffer, VkRenderPass renderPass, int, int) {
                VulkanOverlay(renderPass, commandBuffer);
            });
        ApplyDisplaySettings();
        ApplyVdp2Composite();
    }
    else
    {
        GlBorrow();
        ApplyDisplaySettings();
        GlGiveBack();
    }

    YabaMenu::Host host;
    host.apply_live_settings = ApplyLiveSettings;
    host.paused_frame = [](std::vector<uint8_t> &rgba, int &w, int &h) {
        if (g_pausedFrame.empty())
            return false;
        rgba = g_pausedFrame;
        w = g_pausedFrameW;
        h = g_pausedFrameH;
        return true;
    };
    YabaMenu::Init(host, false);
    YabaMenu::LoadCheats();
    if (!g_startNotice.empty())
        YabaMenu::Notice(g_startNotice);
    if (!biospath[0] && TicoConfig::GetConfigValue("bios", "real") != "emulated")
        OverlayUI::ShowToast(std::string("No Saturn BIOS in ") + tico_system_dir() +
                                 ": the emulated BIOS runs (a few games need the real one)",
                             OverlayUI::ToastCorner::TopRight);
    YabaRA::Init(cdpath);

    LOG_INFO("HOME", "Entering main loop");
    int framesRun = 0;
    u64 saveDirtyAt = 0;
    g_fpsWindowStart = NowMs();

    while (appletMainLoop())
    {
        for (int p = 0; p < MAX_PLAYERS; p++)
            padUpdate(&g_pads[p]);
        UpdatePlayers();
        UpdateScreenMode();

        const bool wasOpen = YabaMenu::IsOpen();
        YabaMenu::Update(padGetButtons(&g_pads[0]), padGetButtonsDown(&g_pads[0]));
        if (YabaMenu::TakeExitRequest())
            break;

        const bool open = YabaMenu::IsOpen();
        if (open && !g_paused)
            Pause();
        else if (!open && g_paused)
            Resume();

        if (open)
        {
            YabaRA::Idle();
            PresentPaused();
            continue;
        }
        // the combo that closed the menu is not the game's
        if (wasOpen)
            continue;

        for (int p = 0; p < g_numPlayers; p++)
            HandleInput(p, &g_pads[p]);
        YabauseExec();
        YabaRA::DoFrame();
        tico::PlaytimeFrame(); // this frame's time to the player's playtime

        // The backup RAM (and a backup RAM cartridge) go to their files a second
        // after the game last wrote them, so a crash or a power-off loses nothing
        // the game saved; a save made of many writes goes out once.
        if (BupRamWritten)
        {
            BupRamWritten = 0;
            saveDirtyAt = NowMs();
        }
        if (saveDirtyAt && NowMs() - saveDirtyAt >= 1000)
        {
            YabFlushBackups();
            saveDirtyAt = 0;
        }

        // the auto save offer, once the game shows
        if (++framesRun == 90)
            YabaMenu::OfferResume();

        g_fpsFrames++;
        const u64 now = NowMs();
        if (now - g_fpsWindowStart >= 1000)
        {
            YabaMenu::SetHud(g_fpsFrames * 1000.0f / (now - g_fpsWindowStart), g_viewportW,
                             g_viewportH);
            g_fpsFrames = 0;
            g_fpsWindowStart = now;
        }
    }

    tico::PlaytimeFlush(); // the game's last seconds

    // Exit Game, Restart or HOME: the game goes to the auto slot first
    const bool restart = YabaMenu::TakeRestartRequest();
    if (!g_paused)
        Pause();
    YabaMenu::AutoSave();
    Resume();

    YabaMenu::Shutdown();
    YabaRA::Shutdown(); // its worker thread, and its sound before the mixer closes
    // stops the VDP thread; the overlay's GPU objects go after it, with the context
    YabauseDeInit();
    ShutdownFrontend();
    g_config.Unload();

    if (!(restart && tico_queue_restart()))
        tico_queue_return();
    appletUnlockExit();
    return 0;
}
