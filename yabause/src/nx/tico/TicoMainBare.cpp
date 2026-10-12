/// @file TicoMainBare.cpp
/// @brief Bare-minimum emulator test — no overlay, no ImGui, no chainloading.
///        Minus+Plus = exit. Async rendering ON.
///
/// Purpose: isolate whether the GPU-OOM crash on exit is caused by the overlay/
///          ImGui layer or by the emulator core itself.
///
/// Copyright 2019 devMiyax(smiyaxdev@gmail.com)
/// Copyright 2025 tico

#include <cstdio>
#include <cstring>
#include <string>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include "TicoLogger.h"

#include <SDL2/SDL.h>
#define GL_GLEXT_PROTOTYPES 1
#include <SDL2/SDL_opengl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <switch.h>

//==============================================================================
// Yabause Core Headers
//==============================================================================

extern "C"
{
#include "config.h"
#include "yabause.h"
#include "vdp2.h"
#include "scsp.h"
#include "vidsoft.h"
#include "vidogl.h"
#include "peripheral.h"
#include "m68kcore.h"
#include "sh2core.h"
#include "sh2int.h"
#include "cdbase.h"
#include "cs2.h"
#include "debug.h"
#include "sndal.h"
#include "sndsdl.h"
#include "osdcore.h"
#include "ygl.h"
}

//==============================================================================
// NX System Configuration
//==============================================================================

extern "C"
{
    u32 __NvOptimusEnablement = 1;
    u32 __NvDeveloperOption = 1;
    u32 __nx_applet_type = AppletType_Application;
    size_t __nx_heap_size = 0;
}

//==============================================================================
// Core Lists (linked by engine)
//==============================================================================

extern "C"
{

    M68K_struct *M68KCoreList[] = {
        &M68KDummy,
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

    VideoInterface_struct *VIDCoreList[] = {
        &VIDDummy,
        &VIDOGL,
        NULL};

#ifdef YAB_PORT_OSD
#include "nanovg/nanovg_osdcore.h"
    OSD_struct *OSDCoreList[] = {
        &OSDNnovg,
        &OSDDummy,
        NULL};
#endif

} // extern "C"

//==============================================================================
// Globals
//==============================================================================

static EGLDisplay s_display = EGL_NO_DISPLAY;
static EGLContext s_context = EGL_NO_CONTEXT;
static EGLSurface s_surface = EGL_NO_SURFACE;

static char biospath[256] = "";
static char cdpath[256] = "";
static char buppath[256] = "./back.bin";
static char mpegpath[256] = "";
static char cartpath[256] = "";

static int g_emulated_bios = 0;
static int g_EnagleFPS = 0;
static bool g_running = true;

static const int MAX_PLAYERS = 2;
static int g_padMode[MAX_PLAYERS] = {0, 0};
static int g_debounce[MAX_PLAYERS] = {0, 0};
static void *g_padbits[MAX_PLAYERS] = {nullptr, nullptr};
static PadState g_pads[MAX_PLAYERS];
static int g_numPlayers = 1;

static int g_viewportX = 0;
static int g_viewportY = 0;
static int g_viewportW = 1280;
static int g_viewportH = 720;

//==============================================================================
// Yabause Callbacks
//==============================================================================

#include "nanovg.h"

extern "C"
{

    NVGcontext *getGlobalNanoVGContext() { return NULL; }
    void DrawDebugInfo() {}
    void YuiErrorMsg(const char *string) { LOG_ERROR("YUI", "%s", string); }

    void YuiSwapBuffers(void)
    {
        if (s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE)
            return;
        eglSwapBuffers(s_display, s_surface);
        SetOSDToggle(g_EnagleFPS);
    }

    int YuiRevokeOGLOnThisThread()
    {
        if (s_display == EGL_NO_DISPLAY)
            return -1;
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        return 0;
    }

    int YuiUseOGLOnThisThread()
    {
        if (s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE || s_context == EGL_NO_CONTEXT)
            return -1;
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        return 0;
    }

} // extern "C"

//==============================================================================
// NxLink Debug
//==============================================================================

#define ENABLE_NXLINK
#ifndef ENABLE_NXLINK
#define TRACE(fmt, ...) ((void)0)
#else
#define TRACE(fmt, ...) printf("%s: " fmt "\n", __PRETTY_FUNCTION__, ##__VA_ARGS__)
static int s_nxlinkSock = -1;

static void initNxLink()
{
    if (R_FAILED(socketInitializeDefault()))
        return;
    s_nxlinkSock = nxlinkStdio();
    if (s_nxlinkSock >= 0)
        TRACE("printf output now goes to nxlink server");
    else
        socketExit();
}

static void deinitNxLink()
{
    if (s_nxlinkSock >= 0)
    {
        close(s_nxlinkSock);
        socketExit();
        s_nxlinkSock = -1;
    }
}
#endif

//==============================================================================
// EGL
//==============================================================================

static bool InitEgl(NWindow *win)
{
    s_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!s_display)
    {
        LOG_ERROR("EGL", "Could not connect to display! error: %d", eglGetError());
        return false;
    }

    eglInitialize(s_display, NULL, NULL);
    eglBindAPI(EGL_OPENGL_API);

    EGLConfig config;
    EGLint numConfigs;
    static const EGLint fbAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE};
    eglChooseConfig(s_display, fbAttribs, &config, 1, &numConfigs);
    if (numConfigs == 0)
    {
        LOG_ERROR("EGL", "No config found! error: %d", eglGetError());
        eglTerminate(s_display);
        s_display = NULL;
        return false;
    }

    s_surface = eglCreateWindowSurface(s_display, config, win, NULL);
    if (!s_surface)
    {
        LOG_ERROR("EGL", "Surface creation failed! error: %d", eglGetError());
        eglTerminate(s_display);
        s_display = NULL;
        return false;
    }

    static const EGLint ctxAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION_KHR, 4,
        EGL_CONTEXT_MINOR_VERSION_KHR, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK_KHR, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT_KHR,
        EGL_NONE};
    s_context = eglCreateContext(s_display, config, EGL_NO_CONTEXT, ctxAttribs);
    if (!s_context)
    {
        LOG_ERROR("EGL", "Context creation failed! error: %d", eglGetError());
        eglDestroySurface(s_display, s_surface);
        s_surface = NULL;
        eglTerminate(s_display);
        s_display = NULL;
        return false;
    }

    eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    eglSwapInterval(s_display, 1);

    LOG_INFO("EGL", "OpenGL %s | %s | %s",
             glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_VENDOR));
    return true;
}

static void DeinitEgl()
{
    if (!s_display)
        return;

    if (eglGetCurrentContext() != s_context)
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);

    glFinish();
    eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    if (s_context)
    {
        eglDestroyContext(s_display, s_context);
        s_context = NULL;
    }
    if (s_surface)
    {
        eglDestroySurface(s_display, s_surface);
        s_surface = NULL;
    }
    eglTerminate(s_display);
    s_display = NULL;
}

//==============================================================================
// Emulator Init — hardcoded defaults, async rendering ON
//==============================================================================

static int InitEmulator()
{
    yabauseinit_struct yinit = {};

    yinit.m68kcoretype = M68KCORE_MUSASHI;
    yinit.percoretype = PERCORE_DUMMY;
#ifdef SH2_DYNAREC
    yinit.sh2coretype = 2;
#elif DYNAREC_DEVMIYAX
    yinit.sh2coretype = 3;
#else
    yinit.sh2coretype = SH2CORE_INTERPRETER;
#endif
    yinit.vidcoretype = VIDCORE_OGL;
    yinit.sndcoretype = SNDCORE_SDL;
    yinit.cdcoretype = CDCORE_ISO;
    yinit.carttype = CART_NONE;
    yinit.regionid = 0;
    yinit.biospath = g_emulated_bios ? NULL : biospath;
    yinit.cdpath = cdpath;
    yinit.buppath = buppath;
    yinit.mpegpath = mpegpath;
    yinit.cartpath = cartpath;

    yinit.videoformattype = VIDEOFORMATTYPE_NTSC;
    yinit.frameskip = 1;
    yinit.framelimit = 0; // 60 Hz
    yinit.usethreads = 1; // ** async rendering ON **
    yinit.use_cpu_affinity = 1;
    yinit.skip_load = 0;
    yinit.video_filter_type = 0;
    yinit.polygon_generation_mode = GPU_TESSERATION;
    yinit.use_new_scsp = 1;
    yinit.resolution_mode = 0; // native
    yinit.rotate_screen = 0;
    yinit.scsp_sync_count_per_frame = 1;
    yinit.extend_backup = 0;
    yinit.scsp_main_mode = 1;
    yinit.rbg_use_compute_shader = 0;
    yinit.rbg_resolution_mode = 0;
    yinit.use_sh2_cache = 1;

    int res = YabauseInit(&yinit);
    if (res == -1)
    {
        LOG_ERROR("EMU", "YabauseInit failed");
        return -1;
    }

    OSDInit(0);
    // NanoVG OSD disabled — no valid NVG context in bare main
    LogStart();

    LOG_INFO("EMU", "Emulator initialized (bios=%s, cd=%s, async=ON)", biospath, cdpath);
    return 0;
}

//==============================================================================
// Arg Parsing (minimal — first arg is ROM path)
//==============================================================================

static void ParseArgs(int argc, char **argv)
{
    std::string romArg;
    for (int i = 1; i < argc; i++)
    {
        if (!argv[i])
            continue;
        std::string arg = argv[i];
        if (arg == "ticoSetup")
            continue;
        if (romArg.empty())
        {
            romArg = arg;
            break;
        }
    }

    if (!romArg.empty())
    {
        strncpy(cdpath, romArg.c_str(), sizeof(cdpath) - 1);
        cdpath[sizeof(cdpath) - 1] = '\0';
    }
    else
    {
        strncpy(cdpath, "sdmc:/tico/roms/saturn/nights/nights.cue", sizeof(cdpath) - 1);
    }
    LOG_INFO("ARGS", "ROM: %s", cdpath);

    // BIOS auto-detect
    const char *biosCandidates[] = {
        "sdmc:/tico/system/saturn/saturn_bios.bin",
        "sdmc:/tiicu/system/saturn/saturn_bios.bin",
        "./yabasanshiro/saturn_bios.bin",
    };
    bool biosFound = false;
    for (const char *cand : biosCandidates)
    {
        struct stat st;
        if (stat(cand, &st) == 0 && st.st_size > 0)
        {
            strncpy(biospath, cand, sizeof(biospath) - 1);
            biospath[sizeof(biospath) - 1] = '\0';
            biosFound = true;
            LOG_INFO("ARGS", "BIOS: %s", biospath);
            break;
        }
    }
    if (!biosFound)
    {
        g_emulated_bios = 1;
        LOG_WARN("ARGS", "No BIOS found — using emulated BIOS");
    }

    // Per-game backup
    {
        std::string romStr(cdpath);
        size_t lastSlash = romStr.find_last_of("/\\");
        std::string romName = (lastSlash != std::string::npos) ? romStr.substr(lastSlash + 1) : romStr;
        size_t lastDot = romName.find_last_of(".");
        if (lastDot != std::string::npos)
            romName = romName.substr(0, lastDot);
        mkdir("sdmc:/tico/saves/saturn/", 0777);
        std::string bup = std::string("sdmc:/tico/saves/saturn/") + romName + ".bup";
        strncpy(buppath, bup.c_str(), sizeof(buppath) - 1);
        buppath[sizeof(buppath) - 1] = '\0';
        LOG_INFO("ARGS", "Backup: %s", buppath);
    }
}

//==============================================================================
// Input
//==============================================================================

#define MAKE_PAD(a, b) ((a << 24) | (b))

static PortData_struct *g_portData[MAX_PLAYERS] = {&PORTDATA1, &PORTDATA2};

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
        if (g_padMode[p] == 1)
            g_padbits[p] = (void *)Per3DPadAdd(g_portData[p]);
        else
            g_padbits[p] = (void *)PerPadAdd(g_portData[p]);
        RegisterPadKeys(p, g_padbits[p]);
    }
}

static void HandleInput(int player, PadState *pad)
{
    u64 kDown = padGetButtons(pad);

    // Face buttons  (Switch A → Saturn A, etc.)
    if (kDown & HidNpadButton_A)
        PerKeyDown(MAKE_PAD(player, PERPAD_A));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_A));
    if (kDown & HidNpadButton_B)
        PerKeyDown(MAKE_PAD(player, PERPAD_B));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_B));
    if (kDown & HidNpadButton_R)
        PerKeyDown(MAKE_PAD(player, PERPAD_C));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_C));
    if (kDown & HidNpadButton_X)
        PerKeyDown(MAKE_PAD(player, PERPAD_X));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_X));
    if (kDown & HidNpadButton_Y)
        PerKeyDown(MAKE_PAD(player, PERPAD_Y));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_Y));
    if (kDown & HidNpadButton_L)
        PerKeyDown(MAKE_PAD(player, PERPAD_Z));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_Z));

    // D-Pad
    if (kDown & HidNpadButton_Left)
        PerKeyDown(MAKE_PAD(player, PERPAD_LEFT));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_LEFT));
    if (kDown & HidNpadButton_Right)
        PerKeyDown(MAKE_PAD(player, PERPAD_RIGHT));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_RIGHT));
    if (kDown & HidNpadButton_Up)
        PerKeyDown(MAKE_PAD(player, PERPAD_UP));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_UP));
    if (kDown & HidNpadButton_Down)
        PerKeyDown(MAKE_PAD(player, PERPAD_DOWN));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_DOWN));

    // Left stick → digital d-pad
    HidAnalogStickState stick = padGetStickPos(pad, 0);
    if (stick.x < -16384)
        PerKeyDown(MAKE_PAD(player, PERPAD_LEFT));
    else if (!(kDown & HidNpadButton_Left))
        PerKeyUp(MAKE_PAD(player, PERPAD_LEFT));
    if (stick.x > 16384)
        PerKeyDown(MAKE_PAD(player, PERPAD_RIGHT));
    else if (!(kDown & HidNpadButton_Right))
        PerKeyUp(MAKE_PAD(player, PERPAD_RIGHT));
    if (stick.y > 16384)
        PerKeyDown(MAKE_PAD(player, PERPAD_UP));
    else if (!(kDown & HidNpadButton_Up))
        PerKeyUp(MAKE_PAD(player, PERPAD_UP));
    if (stick.y < -16384)
        PerKeyDown(MAKE_PAD(player, PERPAD_DOWN));
    else if (!(kDown & HidNpadButton_Down))
        PerKeyUp(MAKE_PAD(player, PERPAD_DOWN));

    // Start + triggers
    if (kDown & HidNpadButton_Plus)
        PerKeyDown(MAKE_PAD(player, PERPAD_START));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_START));
    if (kDown & HidNpadButton_ZR)
        PerKeyDown(MAKE_PAD(player, PERPAD_RIGHT_TRIGGER));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_RIGHT_TRIGGER));
    if (kDown & HidNpadButton_ZL)
        PerKeyDown(MAKE_PAD(player, PERPAD_LEFT_TRIGGER));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_LEFT_TRIGGER));
}

//==============================================================================
// Main
//==============================================================================

int main(int argc, char **argv)
{
    // ---- NRO reload safety: re-init statics ----
    g_running = true;
    g_emulated_bios = 0;
    g_EnagleFPS = 0;
    g_numPlayers = 1;
    g_viewportX = 0;
    g_viewportY = 0;
    g_viewportW = 1280;
    g_viewportH = 720;
    for (int i = 0; i < MAX_PLAYERS; i++)
    {
        g_padMode[i] = 0;
        g_debounce[i] = 0;
        g_padbits[i] = nullptr;
        memset(&g_pads[i], 0, sizeof(g_pads[i]));
    }

    // ---- Switch pre-init ----
    appletLockExit();

    // Ensure log directory exists
    mkdir("sdmc:/tico/debug", 0777);

    // Redirect ALL printf/stdout to a file on the SD card.
    // This captures engine C code (ygles.c, vdp2.cpp, etc.) that uses printf.
    // Use "a" (append) mode so second launch doesn't erase first launch's cleanup output.
    freopen("sdmc:/tico/debug/stdout.txt", "a", stdout);
    setvbuf(stdout, NULL, _IONBF, 0); // unbuffered so we see output even on crash

    printf("\n\n========== NEW LAUNCH ==========\n");

    initNxLink();

    LOG_INFO("BARE", "YabaSanshiro BARE starting (argc=%d)", argc);
    for (int i = 0; i < argc; i++)
        LOG_INFO("BARE", "  argv[%d]='%s'", i, argv[i] ? argv[i] : "(null)");

    Result rc = romfsInit();
    bool romfsOk = R_SUCCEEDED(rc);
    if (!romfsOk)
        LOG_ERROR("BARE", "romfsInit failed: 0x%x", rc);

    // ---- Args ----
    ParseArgs(argc, argv);

    // ---- CPU boost ----
    apmSetPerformanceConfiguration(ApmPerformanceMode_Normal, 0x92220007);
    apmSetPerformanceConfiguration(ApmPerformanceMode_Boost, 0x92220008);

    // ---- EGL ----
    if (!InitEgl(nwindowGetDefault()))
    {
        LOG_ERROR("BARE", "EGL init failed");
        deinitNxLink();
        appletUnlockExit();
        return EXIT_FAILURE;
    }

    // ---- Emulator ----
    if (InitEmulator() == -1)
    {
        LOG_ERROR("BARE", "Emulator init failed");
        DeinitEgl();
        deinitNxLink();
        appletUnlockExit();
        return EXIT_FAILURE;
    }

    // ---- Viewport (4:3 pillarbox) ----
    {
        int w = 1280, h = 720;
        int tw = (h * 4) / 3;
        int th = h;
        if (tw > w)
        {
            tw = w;
            th = (w * 3) / 4;
        }
        g_viewportW = tw;
        g_viewportH = th;
        g_viewportX = (w - tw) / 2;
        g_viewportY = (h - th) / 2;

        VIDCore->Resize(g_viewportX, g_viewportY, g_viewportW, g_viewportH, 0, 0);
        glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    // ---- Controllers ----
    padConfigureInput(MAX_PLAYERS, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&g_pads[0]);
    padInitialize(&g_pads[1], HidNpadIdType_No2);
    g_numPlayers = 1;
    InitPeripherals();

    // ---- Main Loop ----
    LOG_INFO("BARE", "Entering main loop (Minus+Plus = exit)");

    while (g_running)
    {
        if (!appletMainLoop())
        {
            g_running = false;
            break;
        }

        // Scan controllers
        padUpdate(&g_pads[0]);
        if (g_numPlayers >= 2)
            padUpdate(&g_pads[1]);

        u64 kHeld = padGetButtons(&g_pads[0]);

        // ---- Minus + Plus = EXIT ----
        if ((kHeld & HidNpadButton_Minus) && (kHeld & HidNpadButton_Plus))
        {
            LOG_INFO("BARE", "Minus+Plus detected — exiting");
            g_running = false;
            break;
        }

        // Handle input for all active players
        for (int p = 0; p < g_numPlayers; p++)
            HandleInput(p, &g_pads[p]);

        // Run one frame
        YabauseExec();
    }

    // ---- Cleanup ----
    LOG_INFO("BARE", "Cleanup start");

    printf("[BARE-CLEANUP] Starting YabauseDeInit...\n");
    YabauseDeInit();
    printf("[BARE-CLEANUP] YabauseDeInit done\n");
    LOG_INFO("BARE", "YabauseDeInit done");

    // Reclaim GL context (VDP thread released it)
    if (s_display != EGL_NO_DISPLAY && s_surface != EGL_NO_SURFACE && s_context != EGL_NO_CONTEXT)
    {
        EGLBoolean ok = eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        printf("[BARE-CLEANUP] eglMakeCurrent reclaim: %s\n", ok ? "OK" : "FAILED");
    }

    // Final flush to ensure all GPU work is done
    glFinish();
    printf("[BARE-CLEANUP] glFinish done\n");

    SDL_Quit();
    printf("[BARE-CLEANUP] SDL_Quit done\n");
    LOG_INFO("BARE", "SDL_Quit done");

    DeinitEgl();
    printf("[BARE-CLEANUP] DeinitEgl done\n");
    LOG_INFO("BARE", "DeinitEgl done");

    // Flush stdout before exiting so we capture everything
    fflush(stdout);

    romfsExit();
    deinitNxLink();
    appletUnlockExit();

    LOG_INFO("BARE", "Clean exit");
    return 0;
}
