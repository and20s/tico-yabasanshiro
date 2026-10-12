/// @file TicoMain.cpp
/// @brief Entry point for tico-integrated YabaSanshiro NRO
/// Sets up EGL/ImGui and runs the main loop with tico overlay
///
/// Copyright 2019 devMiyax(smiyaxdev@gmail.com)
/// Copyright 2025 tico
///
/// YabaSanshiro is free software; you can redistribute it and/or modify
/// it under the terms of the GNU General Public License as published by
/// the Free Software Foundation; either version 2 of the License, or
/// (at your option) any later version.

#include <exception>
#include <functional>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <fstream>
#include <nlohmann/json.hpp>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/resource.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

#include <SDL2/SDL.h>
#define GL_GLEXT_PROTOTYPES 1
#include <SDL2/SDL_opengl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <switch.h>

// ImGui
#include "imgui.h"
#include "imgui_impl_opengl3.h"

// Tico
#include "TicoOverlay.h"
#include "TicoConfig.h"
#include "TicoLogger.h"
#include "TicoUtils.h"
#include "YabaSanshiroConfig.h"
#include "TicoTranslationManager.h"

// RetroAchievements
#include "rc_client.h"
#include <curl/curl.h>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <SDL_mixer.h>

#include "deps/stb/stb_image.h"
#include "deps/nanosvg/nanosvg.h"
#include "deps/nanosvg/nanosvgrast.h"

static TicoOverlay* g_overlay = nullptr;
static rc_client_t* g_rcClient = nullptr;
static Mix_Chunk* g_trophySound = nullptr;
static bool g_raHardcore = true;

struct RAJob {
    std::string url;
    std::string post_data;
    void* callback;
    void* callback_data;
};

static std::deque<RAJob> g_raJobQueue;
static std::mutex g_raJobMutex;
static std::condition_variable g_raJobCond;
static std::vector<std::function<void()>> g_raPendingCallbacks;
static std::mutex g_raCallbackMutex;
static bool g_raWorkerRunning = false;
static bool g_raThreadCreated = false;

#ifdef __SWITCH__
static Thread g_raThread;
#endif

// Forward Declarations
static void StartRAWorker();
static void StopRAWorker();

struct RANotification {
    std::string title;
    std::string description;
    std::string badge_name;     
    unsigned int textureId = 0; 
    float timer = 0.0f;
    float duration = 4.0f; 
    float slideIn = 0.4f;  
    float slideOut = 0.4f; 
};

static std::vector<RANotification> g_raNotifications;
static unsigned int g_raIconTexture = 0;
static std::map<std::string, unsigned int> g_raBadgeCache;
static std::vector<std::pair<std::string, std::vector<unsigned char>>> g_raPendingBadgeUploads;
static std::mutex g_raBadgeUploadMutex;

// Forward declarations for badge pipeline
static void DownloadAndCacheBadge(const std::string& badge_name);
static void PreloadRABadges();
static void ProcessPendingBadgeUploads();

static void PushRANotification(const std::string& title, const std::string& desc, const std::string& badge)
{
    RANotification n;
    n.title = title;
    n.description = desc;
    n.badge_name = badge;
    n.timer = 0.0f;
    n.textureId = 0;
    if (g_raNotifications.size() >= 5) g_raNotifications.erase(g_raNotifications.begin());
    g_raNotifications.push_back(std::move(n));
}

static unsigned int GetRABadgeTexture(const std::string& badge_name)
{
    auto it = g_raBadgeCache.find(badge_name);
    if (it != g_raBadgeCache.end()) return it->second;
    std::string path = "sdmc:/tico/assets/ra/" + badge_name + ".png";
    FILE* check = fopen(path.c_str(), "rb");
    if (!check) return 0;
    fclose(check);
    int w, h, ch;
    unsigned char* data = stbi_load(path.c_str(), &w, &h, &ch, 4);
    if (data) {
        unsigned int tex = 0;
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
        glBindTexture(GL_TEXTURE_2D, 0);
        stbi_image_free(data);
        g_raBadgeCache[badge_name] = tex;
        return tex;
    }
    return 0;
}

static void RenderRANotifications(ImDrawList *dl, int screenW, int screenH, float deltaTime) {
    if (g_raNotifications.empty()) return;

    // Lazy-load RA icon from SVG if not loaded yet
    if (g_raIconTexture == 0) {
        const char* svgPath = "romfs:/assets/ra.svg";
        NSVGimage* image = nsvgParseFromFile(svgPath, "px", 96);
        if (image) {
            float sc = 64.0f / image->height;
            int w = (int)(image->width * sc), h = (int)(image->height * sc);
            NSVGrasterizer* rast = nsvgCreateRasterizer();
            if (rast) {
                unsigned char* img = (unsigned char*)malloc(w * h * 4);
                if (img) {
                    nsvgRasterize(rast, image, 0, 0, sc, img, w, h, w * 4);
                    glGenTextures(1, &g_raIconTexture);
                    glBindTexture(GL_TEXTURE_2D, g_raIconTexture);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, img);
                    glBindTexture(GL_TEXTURE_2D, 0);
                    free(img);
                }
                nsvgDeleteRasterizer(rast);
            }
            nsvgDelete(image);
        }
    }

    float scale = ImGui::GetIO().FontGlobalScale;
    ImFont *font = ImGui::GetFont();
    ImFont *descFont = font;
    if (ImGui::GetIO().Fonts->Fonts.Size > 1) {
        descFont = ImGui::GetIO().Fonts->Fonts[1];
    }
    float descFontSize = ImGui::GetFontSize() * 0.65f;
    float titleFontSize = ImGui::GetFontSize() * 0.85f;

    float alertW = 420.0f * scale;
    float alertH = 100.0f * scale;
    float padding = 12.0f * scale;
    float margin = 16.0f * scale;
    float spacing = 8.0f * scale;
    float cornerRadius = 14.0f * scale;
    float badgeSize = 76.0f * scale;
    float badgeRadius = 4.0f * scale;
    float badgeMargin = 12.0f * scale;

    bool isRight = true;
    bool isTop = true;

    for (auto& n : g_raNotifications) {
        n.timer += deltaTime;
    }
    g_raNotifications.erase(
        std::remove_if(g_raNotifications.begin(), g_raNotifications.end(),
            [](const RANotification& n) { return n.timer >= n.duration; }),
        g_raNotifications.end());

    for (size_t i = 0; i < g_raNotifications.size(); i++) {
        auto& n = g_raNotifications[i];

        if (n.textureId == 0 && !n.badge_name.empty()) {
            if (n.badge_name == "ra_icon") {
                n.textureId = g_raIconTexture;
            } else {
                n.textureId = GetRABadgeTexture(n.badge_name);
            }
        }

        float slideProgress;
        if (n.timer < n.slideIn) {
            float t = n.timer / n.slideIn;
            slideProgress = 1.0f - std::pow(1.0f - t, 3.0f);
        } else if (n.timer > n.duration - n.slideOut) {
            float t = (n.duration - n.timer) / n.slideOut;
            slideProgress = 1.0f - std::pow(1.0f - t, 3.0f);
        } else {
            slideProgress = 1.0f;
        }

        float stackOffset = (float)i * (alertH + spacing);
        float anchorX = isRight ? (screenW - alertW - margin) : margin;
        float anchorY = isTop ? (margin + stackOffset) : (screenH - margin - alertH - stackOffset);
        float slideOffsetY = isTop
            ? -(alertH + margin + stackOffset) * (1.0f - slideProgress)
            : (alertH + margin + stackOffset) * (1.0f - slideProgress);

        float drawY = anchorY + slideOffsetY;
        int alpha = (int)(230 * slideProgress);
        if (alpha <= 0) continue;

        ImVec2 rectMin(anchorX, drawY);
        ImVec2 rectMax(anchorX + alertW, drawY + alertH);

        bool isDarkMode = (g_overlay && g_overlay->IsDarkMode());
        ImU32 bgColor = isDarkMode
            ? IM_COL32(35, 35, 40, alpha)
            : IM_COL32(245, 248, 252, alpha);
        ImU32 borderColor = isDarkMode
            ? IM_COL32(70, 70, 80, (int)(180 * slideProgress))
            : IM_COL32(200, 205, 215, (int)(200 * slideProgress));

        dl->AddRectFilled(rectMin, rectMax, bgColor, cornerRadius);
        dl->AddRect(rectMin, rectMax, borderColor, cornerRadius, 0, 1.5f * scale);

        float textX = rectMin.x + padding;
        if (n.textureId != 0) {
            float badgeX = rectMin.x + badgeMargin;
            float badgeY = rectMin.y + (alertH - badgeSize) * 0.5f;

            float drawBadgeSize = badgeSize;
            float drawBadgeX = badgeX;
            float drawBadgeY = badgeY;

            if (n.badge_name == "ra_icon") {
                drawBadgeSize = badgeSize * 0.70f;
                drawBadgeX += (badgeSize - drawBadgeSize) * 0.5f;
                drawBadgeY += (badgeSize - drawBadgeSize) * 0.5f;
            }

            ImVec2 bMin(drawBadgeX, drawBadgeY);
            ImVec2 bMax(drawBadgeX + drawBadgeSize, drawBadgeY + drawBadgeSize);
            ImU32 imgCol = IM_COL32(255, 255, 255, alpha);
            dl->AddImageRounded((ImTextureID)(uintptr_t)n.textureId,
                bMin, bMax, ImVec2(0,0), ImVec2(1,1), imgCol, badgeRadius);
            
            textX = badgeX + badgeSize + badgeMargin;
        }

        ImU32 descColor = isDarkMode
            ? IM_COL32(185, 185, 195, alpha)
            : IM_COL32(80, 80, 95, alpha);
        float maxDescW = rectMax.x - textX - padding;

        ImU32 titleColor = isDarkMode
            ? IM_COL32(255, 255, 255, alpha)
            : IM_COL32(30, 30, 40, alpha);

        std::string desc = n.description;
        float maxDescH = descFontSize * 2.5f;
        ImVec2 fullSize = descFont->CalcTextSizeA(descFontSize, FLT_MAX, maxDescW, desc.c_str());
        
        if (fullSize.y > maxDescH) {
            desc += "...";
            while (desc.length() > 4) {
                ImVec2 testSize = descFont->CalcTextSizeA(descFontSize, FLT_MAX, maxDescW, desc.c_str());
                if (testSize.y <= maxDescH) break;
                desc.erase(desc.length() - 4, 1);
            }
        }

        std::string titleStr = n.title;
        ImVec2 titleSize = font->CalcTextSizeA(titleFontSize, FLT_MAX, 0.0f, titleStr.c_str());
        if (titleSize.x > maxDescW) {
            titleStr += "...";
            while (titleStr.length() > 4) {
                ImVec2 testSize = font->CalcTextSizeA(titleFontSize, FLT_MAX, 0.0f, titleStr.c_str());
                if (testSize.x <= maxDescW) break;
                titleStr.erase(titleStr.length() - 4, 1);
            }
            titleSize = font->CalcTextSizeA(titleFontSize, FLT_MAX, 0.0f, titleStr.c_str());
        }

        ImVec2 descSize = descFont->CalcTextSizeA(descFontSize, FLT_MAX, maxDescW, desc.c_str());
        
        float textSpacing = 4.0f * scale;
        float totalTextH = titleSize.y + textSpacing + descSize.y;
        float titleY = rectMin.y + (alertH - totalTextH) * 0.5f;
        float descY = titleY + titleSize.y + textSpacing;

        dl->AddText(font, titleFontSize,
            ImVec2(textX + 1.0f, titleY + 1.0f),
            IM_COL32(0, 0, 0, (int)(80 * slideProgress)),
            titleStr.c_str());
        dl->AddText(font, titleFontSize,
            ImVec2(textX, titleY), titleColor, titleStr.c_str());

        dl->AddText(descFont, descFontSize, ImVec2(textX, descY), descColor, desc.c_str(), nullptr, maxDescW);
    }
}


//==============================================================================
// Yabause Core Headers (extern "C" — required by the engine)
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
#include "memory.h"
}

//==============================================================================
// NX System Configuration (extern "C")
//==============================================================================

extern "C"
{
    u32 __NvOptimusEnablement = 1;
    u32 __NvDeveloperOption = 1;
    u32 __nx_applet_type = AppletType_Application;
    size_t __nx_heap_size = 0;
}

//==============================================================================
// Yabause Core Lists (extern "C" — linked by engine)
//==============================================================================

extern "C"
{
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
}

//==============================================================================
// Globals
//==============================================================================

static EGLDisplay s_display = EGL_NO_DISPLAY;
static EGLContext s_context = EGL_NO_CONTEXT;
static EGLContext s_context_sub = EGL_NO_CONTEXT; // Shared context for rotation thread (compute shaders)
static EGLSurface s_surface = EGL_NO_SURFACE;
static EGLSurface s_pbuffer = EGL_NO_SURFACE; // PBuffer surface for sub-context (compute shaders)
static EGLConfig s_config = NULL; // Stored for reference
static pthread_t s_main_thread_id = 0; // The main thread ID

// Emulator paths
static char biospath[256] = "";
static char cdpath[256] = "";
static char buppath[256] = "./back.bin";
static char mpegpath[256] = "\0";
static char cartpath[256] = "\0";

// Emulator config (loaded from YabaSanshiroConfig)
static YabaSanshiroConfig g_yabaSanshiroConfig;
static int g_EnagleFPS = 0;
static int g_resolution_mode = 0;
static int g_scsp_sync = 1;
static int g_frame_skip = 0;
static int g_emulated_bios = 0;

// Engine aspect ratio mode (ASPECT_RATE_MODE from ygl.h):
// ORIGINAL=0, _4_3=1, _16_9=2, FULL=3
// The engine handles pillarbox/letterbox internally in SetSaturnResolution.
static int g_engineAspectMode = 1; // Default: 4:3

static bool g_running = true;

// Multi-player support: Saturn has 2 controller ports
static const int MAX_PLAYERS = 2;

// Per-player pad mode: 0 = Standard Pad (Digital Only), 1 = 3D Pad (Analog+Digital)
static int g_padMode[MAX_PLAYERS] = {0, 0};
static int g_debounce[MAX_PLAYERS] = {0, 0};
static void *g_padbits[MAX_PLAYERS] = {nullptr, nullptr};
static PadState g_pads[MAX_PLAYERS];
static int g_numPlayers = 1; // Active player count (detected at runtime)

// Joy-Con SixAxis Handles
static HidSixAxisSensorHandle g_sixaxis_handles[MAX_PLAYERS][4];

// Pad mode toast (frames remaining per player, ~2 seconds = 120 frames)
static int g_padToast[MAX_PLAYERS] = {0, 0};
static const int PAD_TOAST_DURATION = 120;

static int SanitizePadMode(int padMode)
{
    return (padMode == 1) ? 1 : 0;
}

// Overlay pause state
static GLuint g_capturedFrameTex = 0;
static bool g_wasPaused = false;

// Viewport (emulator rendering area)
static int g_viewportX = 0;
static int g_viewportY = 0;
static int g_viewportW = 1280;
static int g_viewportH = 720;

// Screen dimensions (dynamic: 1280x720 handheld, 1920x1080 docked)
static int g_screenW = 1280;
static int g_screenH = 720;
static u8 g_lastOperationMode = 255; // Invalid initial → forces first update

// Last applied in-game display settings (for re-applying on mode change)
static int g_lastDisplayMode = 1; // SaturnDisplayMode::Display
static int g_lastDisplaySize = 1; // SaturnDisplaySize::_4_3

//==============================================================================
// Yabause Callbacks (extern "C" — called by the engine)
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

        // Render pad mode toast, crosshairs, and RA notifications on top of game frame (before swap)
        bool anyToast = false;
        bool anyLightGun = false;
        bool anyRANotif = !g_raNotifications.empty();
        for (int p = 0; p < MAX_PLAYERS; p++) {
            if (g_padToast[p] > 0)
                anyToast = true;
            if (g_padMode[p] == 2 && g_padbits[p] != nullptr)
                anyLightGun = true;
        }

        if (anyToast || anyLightGun || anyRANotif)
        {
            // Save GL state the emulator may rely on
            glViewport(0, 0, g_screenW, g_screenH);

            ImGui_ImplOpenGL3_NewFrame();
            ImGui::NewFrame();

            ImDrawList *fg = ImGui::GetForegroundDrawList();
            const float screenW = (float)g_screenW;
            const float marginX = 24.0f;  // margin from screen edge
            const float marginY = 16.0f;  // margin from top
            const float padX = 16.0f;     // horizontal padding inside pill
            const float padY = 8.0f;      // vertical padding inside pill
            const float rounding = 14.0f; // pill corner radius

            for (int p = 0; p < MAX_PLAYERS; p++)
            {
                if (g_padToast[p] <= 0)
                    continue;

                // Fade out in last 30 frames
                float alpha = 1.0f;
                if (g_padToast[p] < 30)
                    alpha = g_padToast[p] / 30.0f;

                const char *mode = "Standard";
                if (g_padMode[p] == 1) mode = "3D Pad";
                else if (g_padMode[p] == 2) mode = "Light Gun";
                
                char label[32];
                snprintf(label, sizeof(label), "P%d - %s", p + 1, mode);

                ImVec2 textSize = ImGui::CalcTextSize(label);

                // Pill position: P1 left, P2 right
                float pillW = textSize.x + padX * 2;
                float pillH = textSize.y + padY * 2;
                float pillX;
                if (p == 0)
                    pillX = marginX;
                else
                    pillX = screenW - pillW - marginX;
                float pillY = marginY;

                // Pill background: 60% black
                ImU32 bgCol = IM_COL32(0, 0, 0, (int)(alpha * 153));
                fg->AddRectFilled(
                    ImVec2(pillX, pillY),
                    ImVec2(pillX + pillW, pillY + pillH),
                    bgCol, rounding);

                // Text centered in pill
                ImU32 textCol = IM_COL32(255, 255, 255, (int)(alpha * 240));
                fg->AddText(
                    ImVec2(pillX + padX, pillY + padY),
                    textCol, label);

                g_padToast[p]--;
            }

            // Draw Crosshairs for Light Guns
            for (int p = 0; p < MAX_PLAYERS; p++)
            {
                if (g_padMode[p] == 2 && g_padbits[p] != nullptr)
                {
                    PerGun_struct *gun = (PerGun_struct *)g_padbits[p];
                    
                    // The gunbits contain the absolute X/Y of the gun cursor
                    // X is 16-bit at index 1 (high) and 2 (low)
                    // Y is 16-bit at index 3 (high) and 4 (low)
                    int gunX = (gun->gunbits[1] << 8) | gun->gunbits[2];
                    int gunY = (gun->gunbits[3] << 8) | gun->gunbits[4];

                    // Convert from Saturn viewport (320x224 typical, up to 704x480) 
                    // to screen viewport. 
                    // Note: Yabause usually normalizes the lightgun coordinates to 320x224 internally
                    // (see PerGunMove in peripheral.c). We need to scale this to screen W/H.
                    float screenX = g_viewportX + ((float)gunX / 320.0f) * g_viewportW;
                    float screenY = g_viewportY + ((float)gunY / 224.0f) * g_viewportH;

                    ImVec2 center(screenX, screenY);
                    
                    ImU32 crosshairColor = (p == 0) ? IM_COL32(255, 0, 0, 255) : IM_COL32(0, 0, 255, 255);
                    const float radius = 10.0f;
                    
                    // Draw a circle and cross
                    fg->AddCircle(center, radius, crosshairColor, 12, 2.0f);
                    fg->AddLine(ImVec2(center.x - radius - 5, center.y), ImVec2(center.x + radius + 5, center.y), crosshairColor, 2.0f);
                    fg->AddLine(ImVec2(center.x, center.y - radius - 5), ImVec2(center.x, center.y + radius + 5), crosshairColor, 2.0f);
                }
            }

            // Draw RA notifications
            if (anyRANotif) {
                RenderRANotifications(fg, g_screenW, g_screenH, ImGui::GetIO().DeltaTime);
            }

            ImGui::Render();
            ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

            // Restore emulator viewport
            glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
        }

        eglSwapBuffers(s_display, s_surface);

        // Clear the fresh back buffer fully black for clean letterbox borders.
        // After eglSwapBuffers, the new back buffer is undefined — without this,
        // the area outside the emulator viewport (letterbox borders) would show
        // garbage. The emulator's VDP thread will render game content into the
        // viewport sub-rect on top of this clean black canvas.
        glViewport(0, 0, g_screenW, g_screenH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);

        SetOSDToggle(0);
    }

    int YuiRevokeOGLOnThisThread()
    {
        if (s_display == EGL_NO_DISPLAY)
            return -1;
        if (yabsys.UseAsyncRendering)
        {
            // Check if sub-context is already current on this thread (avoid EGL_BAD_ACCESS)
            EGLContext currentCtx = eglGetCurrentContext();
            if (currentCtx == s_context_sub)
            {
                // Already on sub-context, nothing to do
                return 0;
            }

            // DO NOT let the main thread bind s_context_sub! The main thread has no business with it,
            // and doing so during initialization starves the VDP thread and causes EGL_BAD_ACCESS (0x3002).
            if (pthread_self() == s_main_thread_id)
            {
                eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                return 0;
            }

            // Switch to the shared sub-context with PBuffer surface.
            // This allows other threads (like rotation thread) to make GL calls
            // while the VDP thread doesn't need the main context.
            // The sub-context shares resources with the main context.
            if (s_context_sub != EGL_NO_CONTEXT && s_pbuffer != EGL_NO_SURFACE)
            {
                LOG_INFO("EGL", "YuiRevokeOGLOnThisThread: switching to sub-context %p with pbuffer %p", s_context_sub, s_pbuffer);
                if (!eglMakeCurrent(s_display, s_pbuffer, s_pbuffer, s_context_sub))
                {
                    LOG_ERROR("EGL", "YuiRevokeOGLOnThisThread: pbuffer sub-context switch failed! error: 0x%x", eglGetError());
                    // Fallback: try surfaceless mode (KHR_surfaceless_context)
                    if (!eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, s_context_sub))
                    {
                        LOG_ERROR("EGL", "YuiRevokeOGLOnThisThread: surfaceless fallback also failed! error: 0x%x", eglGetError());
                        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                    }
                }
            }
            else if (s_context_sub != EGL_NO_CONTEXT)
            {
                // No PBuffer, try surfaceless mode
                LOG_WARN("EGL", "YuiRevokeOGLOnThisThread: no pbuffer, trying surfaceless sub-context %p", s_context_sub);
                if (!eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, s_context_sub))
                {
                    LOG_ERROR("EGL", "YuiRevokeOGLOnThisThread: surfaceless sub-context failed! error: 0x%x", eglGetError());
                    eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                }
            }
            else
            {
                LOG_WARN("EGL", "YuiRevokeOGLOnThisThread: no sub-context available, unbinding completely");
                eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            }
        }
        return 0;
    }

    int YuiUseOGLOnThisThread()
    {
        if (s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE || s_context == EGL_NO_CONTEXT)
            return -1;
        if (yabsys.UseAsyncRendering)
        {
            // Check if main context is already current on this thread
            if (eglGetCurrentContext() == s_context)
                return 0;
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        }
        return 0;
    }
}

//==============================================================================
// NxLink Debug (Removed)
//==============================================================================

#define TRACE(fmt, ...) ((void)0)

//==============================================================================
// EGL Init/Deinit
//==============================================================================

static bool InitEgl(NWindow *win)
{
    s_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!s_display)
    {
        TRACE("Could not connect to display! error: %d", eglGetError());
        return false;
    }

    eglInitialize(s_display, NULL, NULL);
    eglBindAPI(EGL_OPENGL_API);

    EGLConfig config;
    EGLint numConfigs;
    // Note: We use KHR_surfaceless_context for sub-context, so no PBUFFER_BIT needed
    static const EGLint fbAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE};
    eglChooseConfig(s_display, fbAttribs, &config, 1, &numConfigs);
    if (numConfigs == 0)
    {
        TRACE("No EGL config found! error: %d", eglGetError());
        eglTerminate(s_display);
        s_display = NULL;
        return false;
    }

    s_surface = eglCreateWindowSurface(s_display, config, win, NULL);
    if (!s_surface)
    {
        TRACE("Surface creation failed! error: %d", eglGetError());
        eglTerminate(s_display);
        s_display = NULL;
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
        TRACE("Context creation failed! error: %d", eglGetError());
        eglDestroySurface(s_display, s_surface);
        s_surface = NULL;
        eglTerminate(s_display);
        s_display = NULL;
        return false;
    }

    // Create shared sub-context for rotation thread (compute shaders with async rendering)
    // This context shares resources (textures, buffers) with the main context
    LOG_INFO("EGL", "Creating shared sub-context for compute shader support...");
    s_context_sub = eglCreateContext(s_display, config, s_context, ctxAttribs);
    if (!s_context_sub)
    {
        LOG_ERROR("EGL", "Sub-context creation failed! error: 0x%x (compute shaders may not work with async rendering)", eglGetError());
        // Non-fatal: compute shaders just won't work with async rendering
    }
    else
    {
        LOG_INFO("EGL", "Sub-context created successfully: %p (shared with main: %p)", s_context_sub, s_context);
        
        // Create a 1x1 PBuffer surface for the sub-context
        // This is needed to make the sub-context current for compute shader dispatch
        const EGLint pbufferAttribs[] = {
            EGL_WIDTH, 1,
            EGL_HEIGHT, 1,
            EGL_NONE
        };
        s_pbuffer = eglCreatePbufferSurface(s_display, config, pbufferAttribs);
        if (s_pbuffer == EGL_NO_SURFACE)
        {
            LOG_WARN("EGL", "PBuffer creation failed! error: 0x%x - will use surfaceless context as fallback", eglGetError());
        }
        else
        {
            LOG_INFO("EGL", "PBuffer surface created: %p (1x1 for sub-context)", s_pbuffer);
        }
    }

    s_config = config; // Store for later use
    eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    eglSwapInterval(s_display, 1); // VSync (60 Hz)

    LOG_INFO("EGL", "OpenGL %s | %s | %s",
             glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_VENDOR));
    return true;
}

static void DeinitEgl()
{
    if (!s_display)
        return;

    FILE *dbg;

    // Ensure GL context is current on this thread before glFinish().
    // This is needed for BOTH async and non-async modes — in non-async mode
    // the context might have been implicitly unbound, and in async mode the
    // VDP thread released it during shutdown.
    if (s_surface != EGL_NO_SURFACE && s_context != EGL_NO_CONTEXT)
    {
        if (eglGetCurrentContext() != s_context)
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    }

    glFinish();

    // CRITICAL: Unbind context BEFORE destroying it.
    // This is required for both async and non-async modes — destroying a
    // context while it's still current can cause hangs on some drivers.
    eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    // Clean up sub-context and pbuffer (for async rendering compute shader support)
    if (s_context_sub)
    {
        eglDestroyContext(s_display, s_context_sub);
        s_context_sub = EGL_NO_CONTEXT;
    }
    if (s_pbuffer)
    {
        eglDestroySurface(s_display, s_pbuffer);
        s_pbuffer = EGL_NO_SURFACE;
    }

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

    s_config = NULL;
    eglTerminate(s_display);
    s_display = EGL_NO_DISPLAY;

    // Chainloaded NROs can inherit main-thread TLS, so explicitly drop
    // any remaining per-thread EGL state after the display is gone.
    eglReleaseThread();
}

//==============================================================================
// RetroAchievements Callbacks
//==============================================================================

static uint32_t RC_CCONV RAReadMemory(uint32_t address, uint8_t* buffer, uint32_t num_bytes, rc_client_t* client)
{
    // Saturn map for RetroAchievements:
    // 0x000000 - 0x0FFFFF -> Low WRAM  (1MB)
    // 0x100000 - 0x1FFFFF -> High WRAM (1MB)
    // 0x200000 - 0x2FFFFF -> Backup RAM ...
    
    // Yabause exposes LowWram (1MB) and HighWram (1MB)
    if (address < 0x100000 && (address + num_bytes) <= 0x100000) {
        if (LowWram) memcpy(buffer, LowWram + address, num_bytes);
        return num_bytes;
    }
    else if (address >= 0x100000 && (address + num_bytes) <= 0x200000) {
        if (HighWram) memcpy(buffer, HighWram + (address - 0x100000), num_bytes);
        return num_bytes;
    }
    
    return 0;
}

static size_t RACurlWriteCallback(void *contents, size_t size, size_t nmemb, void *userp) {
    ((std::string*)userp)->append((char*)contents, size * nmemb);
    return size * nmemb;
}

static void RAWorkerEntry(void* arg) {
    while (true) {
        RAJob job;
        {
            std::unique_lock<std::mutex> lock(g_raJobMutex);
            g_raJobCond.wait(lock, []() {
                return !g_raJobQueue.empty() || !g_raWorkerRunning;
            });
            if (!g_raWorkerRunning && g_raJobQueue.empty()) break;
            job = std::move(g_raJobQueue.front());
            g_raJobQueue.pop_front();
        }
        // Handle badge download jobs
        if (job.url == "__badge__") {
            DownloadAndCacheBadge(job.post_data);
            continue;
        }
        
        CURL *curl = curl_easy_init();
        std::string readBuffer;
        long http_code = 0;
        
        LOG_INFO("RA", "Worker pulling URL: %s", job.url.c_str());
        
        if (curl) {
            curl_easy_setopt(curl, CURLOPT_URL, job.url.c_str());
            if (!job.post_data.empty()) curl_easy_setopt(curl, CURLOPT_POSTFIELDS, job.post_data.c_str());
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, RACurlWriteCallback);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
            curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
            curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
            curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
            CURLcode res = curl_easy_perform(curl);
            if (res == CURLE_OK) {
                curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
                LOG_INFO("RA", "Worker finished %s (HTTP %ld)", job.url.c_str(), http_code);
            } else {
                http_code = 500;
                LOG_ERROR("RA", "Curl failed for %s: %s", job.url.c_str(), curl_easy_strerror(res));
            }
            curl_easy_cleanup(curl);
        }
        {
            std::lock_guard<std::mutex> lock(g_raCallbackMutex);
            g_raPendingCallbacks.push_back([job, http_code, readBuffer]() {
                rc_api_server_response_t response;
                memset(&response, 0, sizeof(response));
                response.body = readBuffer.c_str();
                response.body_length = readBuffer.size();
                response.http_status_code = http_code;
                rc_client_server_callback_t cb = (rc_client_server_callback_t)job.callback;
                if (cb) cb(&response, job.callback_data);
            });
        }
    }
}

static void StartRAWorker() {
#ifdef __SWITCH__
    g_raWorkerRunning = true;
    memset(&g_raThread, 0, sizeof(g_raThread));
    Result rc = threadCreate(&g_raThread, RAWorkerEntry, NULL, NULL, 0x40000, 0x2C, 0);
    if (R_SUCCEEDED(rc)) {
        if (R_SUCCEEDED(threadStart(&g_raThread))) {
            g_raThreadCreated = true;
        } else {
            threadClose(&g_raThread);
            g_raWorkerRunning = false;
        }
    } else {
        g_raWorkerRunning = false;
    }
#endif
}

static void StopRAWorker() {
#ifdef __SWITCH__
    if (!g_raThreadCreated) return;
    {
        std::lock_guard<std::mutex> lock(g_raJobMutex);
        g_raWorkerRunning = false;
    }
    g_raJobCond.notify_one();
    threadWaitForExit(&g_raThread);
    threadClose(&g_raThread);
    g_raThreadCreated = false;
#endif
}

static void DownloadAndCacheBadge(const std::string& badge_name)
{
    std::string cachePath = "sdmc:/tico/assets/ra/" + badge_name + ".png";
    FILE* check = fopen(cachePath.c_str(), "rb");
    if (check) { fclose(check); return; }
    std::string url = "https://media.retroachievements.org/Badge/" + badge_name + ".png";
    std::string response;
    CURL* curl = curl_easy_init();
    if (!curl) return;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, RACurlWriteCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    CURLcode res = curl_easy_perform(curl);
    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
    curl_easy_cleanup(curl);
    if (res != CURLE_OK || httpCode != 200 || response.empty()) return;
    mkdir("sdmc:/tico/assets/ra", 0777);
    FILE* fp = fopen(cachePath.c_str(), "wb");
    if (fp) {
        fwrite(response.data(), 1, response.size(), fp);
        fclose(fp);
    }
}

static void PreloadRABadges()
{
    if (!g_rcClient) return;
    rc_client_achievement_list_t* list = rc_client_create_achievement_list(g_rcClient,
        RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE_AND_UNOFFICIAL, RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_PROGRESS);
    if (!list) return;
    std::vector<std::string> badges;
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        for (uint32_t a = 0; a < list->buckets[b].num_achievements; a++) {
            const rc_client_achievement_t* ach = list->buckets[b].achievements[a];
            if (ach && ach->badge_name[0]) {
                std::string bn = ach->badge_name;
                std::string path = "sdmc:/tico/assets/ra/" + bn + ".png";
                FILE* check = fopen(path.c_str(), "rb");
                if (check) { fclose(check); continue; }
                badges.push_back(bn);
            }
        }
    }
    rc_client_destroy_achievement_list(list);
    for (const auto& badge : badges) {
        std::lock_guard<std::mutex> lock(g_raJobMutex);
        RAJob job; job.url = "__badge__"; job.post_data = badge; job.callback = nullptr;
        g_raJobQueue.push_back(std::move(job));
    }
    g_raJobCond.notify_one();
}

static void ProcessPendingBadgeUploads()
{
    std::vector<std::pair<std::string, std::vector<unsigned char>>> uploads;
    {
        std::lock_guard<std::mutex> lock(g_raBadgeUploadMutex);
        if (g_raPendingBadgeUploads.empty()) return;
        uploads = std::move(g_raPendingBadgeUploads);
    }
    for (auto& [name, data] : uploads) {
        if (data.empty()) continue;
        int w, h, ch;
        unsigned char* pixels = stbi_load_from_memory(data.data(), (int)data.size(), &w, &h, &ch, 4);
        if (pixels) {
            unsigned int tex = 0;
            glGenTextures(1, &tex);
            glBindTexture(GL_TEXTURE_2D, tex);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            glBindTexture(GL_TEXTURE_2D, 0);
            stbi_image_free(pixels);
            g_raBadgeCache[name] = tex;
        }
    }
}

static void RC_CCONV RAServerCall(const rc_api_request_t* request, rc_client_server_callback_t callback, void* callback_data, rc_client_t* client)
{
    RAJob job;
    job.url = request->url;
    if (request->post_data) job.post_data = request->post_data;
    job.callback = (void*)callback;
    job.callback_data = callback_data;
    
#ifdef __SWITCH__
    if (g_raWorkerRunning) {
        std::lock_guard<std::mutex> lock(g_raJobMutex);
        g_raJobQueue.push_back(std::move(job));
        g_raJobCond.notify_one();
    } else {
        CURL *curl = curl_easy_init();
        std::string readBuffer;
        long http_code = 0;
        if (curl) {
            curl_easy_setopt(curl, CURLOPT_URL, request->url);
            if (request->post_data) curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request->post_data);
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, RACurlWriteCallback);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
            curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
            CURLcode res = curl_easy_perform(curl);
            if (res == CURLE_OK) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
            else http_code = 500;
            curl_easy_cleanup(curl);
        }
        rc_api_server_response_t response;
        memset(&response, 0, sizeof(response));
        response.body = readBuffer.c_str();
        response.body_length = readBuffer.size();
        response.http_status_code = http_code;
        if (callback) callback(&response, callback_data);
    }
#endif
}

static void RAInit(const char* rom_path) {
    std::string accountsPath = "sdmc:/tico/config/accounts.jsonc";
    std::ifstream file(accountsPath);
    std::string username, token, password;
    bool enabled = false;
    
    if (file.is_open()) {
        nlohmann::json j = nlohmann::json::parse(file, nullptr, false, true);
        if (!j.is_discarded() && j.is_object()) {
            enabled = j.value("ra_enabled", false);
            username = j.value("ra_username", "");
            token = j.value("ra_token", "");
            password = j.value("ra_password", "");
            g_raHardcore = j.value("ra_hardcore_mode", false);
        }
    }
    
    if (!enabled) return;
    
    g_rcClient = rc_client_create(RAReadMemory, RAServerCall);
    if (!g_rcClient) return;
    
    // Load trophy sound effect
    g_trophySound = Mix_LoadWAV("romfs:/assets/trophy.mp3");
    
    rc_client_set_event_handler(g_rcClient, [](const rc_client_event_t* event, rc_client_t* client) {
        if (!g_overlay) return;
        switch (event->type) {
            case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
                if (event->achievement) {
                    LOG_INFO("RA", "Achievement Unlocked: %s - %s", event->achievement->title, event->achievement->description);
                    PushRANotification(event->achievement->title, event->achievement->description, event->achievement->badge_name);
                    if (g_trophySound) Mix_PlayChannel(-1, g_trophySound, 0);
                }
                break;
            case RC_CLIENT_EVENT_GAME_COMPLETED:
                LOG_INFO("RA", "Game Mastered! All achievements unlocked!");
                PushRANotification("Game Mastered!", "All achievements unlocked!", "ra_icon");
                if (g_trophySound) Mix_PlayChannel(-1, g_trophySound, 0);
                break;
            case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
                if (event->leaderboard) {
                    LOG_INFO("RA", "Leaderboard Submitted: %s", event->leaderboard->title);
                    PushRANotification("Leaderboard", event->leaderboard->title, "ra_icon");
                }
                break;
            default:
                break;
        }
    });
    rc_client_set_hardcore_enabled(g_rcClient, g_raHardcore);
    StartRAWorker();
    
    static std::string s_activePath;
    s_activePath = rom_path;

    // Login and identify
    if (!username.empty() && (!token.empty() || !password.empty())) {
        LOG_INFO("RA", "Trying login for %s...", username.c_str());
        
        auto onLogin = [](int res, const char* err, rc_client_t* c, void* ud) {
            if (res == RC_OK) {
                LOG_INFO("RA", "Login successful! Starting identify...");
                // Sega Saturn = 39 in rcheevos
                rc_client_begin_identify_and_load_game(c, 39, s_activePath.c_str(), nullptr, 0,
                    [](int r, const char* e, rc_client_t* c2, void* ud2) {
                        if (r == RC_OK) {
                            const rc_client_game_t* game = rc_client_get_game_info(c2);
                            if (game && game->title) {
                                LOG_INFO("RA", "Playing identified game: %s", game->title);
                                PushRANotification("RetroAchievements", std::string("Playing: ") + game->title, "ra_icon");
                                PreloadRABadges();
                            } else {
                                LOG_INFO("RA", "Playing identified game: Unknown Title");
                                PushRANotification("RetroAchievements", "Playing: Unknown Title", "ra_icon");
                            }
                        } else {
                            LOG_WARN("RA", "Game identify failed: %s", e ? e : "unknown");
                            PushRANotification("RetroAchievements", std::string("Identify failed: ") + (e ? e : "unknown"), "ra_icon");
                        }
                    }, nullptr);
            } else {
                LOG_ERROR("RA", "Login failed: %s", err ? err : "unknown");
                PushRANotification("RetroAchievements", std::string("Login failed: ") + (err ? err : "unknown"), "ra_icon");
            }
        };

        if (!token.empty()) {
            rc_client_begin_login_with_token(g_rcClient, username.c_str(), token.c_str(), onLogin, nullptr);
        } else {
            rc_client_begin_login_with_password(g_rcClient, username.c_str(), password.c_str(), onLogin, nullptr);
        }
    }
}

//==============================================================================
// ImGui Init
//==============================================================================

static bool InitImGui(bool romfsAvailable)
{
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)g_screenW, (float)g_screenH);
    io.IniFilename = nullptr;

    // Load font — romfs first, sdmc fallback
    ImFont *font = nullptr;
    if (romfsAvailable)
        font = io.Fonts->AddFontFromFileTTF(TicoConfig::FONT_PATH, TicoConfig::FONT_SIZE);
    if (!font)
        font = io.Fonts->AddFontFromFileTTF("sdmc:/tiicu/assets/fonts/font.ttf", TicoConfig::FONT_SIZE);
    if (!font)
    {
        LOG_WARN("IMGUI", "Custom font not found, using ImGui default");
        io.Fonts->AddFontDefault();
    }
    io.Fonts->Build();

    ImGui_ImplOpenGL3_Init("#version 430");
    LOG_INFO("IMGUI", "ImGui initialized");
    return true;
}

//==============================================================================
// Emulator Init
//==============================================================================

static int InitEmulator()
{
    yabauseinit_struct yinit = {};

    yinit.m68kcoretype = M68KCORE_MUSASHI;
    yinit.percoretype = PERCORE_DUMMY;
#ifdef SH2_DYNAREC
    yinit.sh2coretype = 2;
#elif DYNAREC_DEVMIYAX
    yinit.sh2coretype = 3; // devmiyax dynarec
#else
    yinit.sh2coretype = SH2CORE_INTERPRETER;
#endif
    yinit.vidcoretype = VIDCORE_OGL;
    yinit.sndcoretype = SNDCORE_SDL;
    yinit.cdcoretype = CDCORE_ISO;
    yinit.carttype = g_yabaSanshiroConfig.GetCartridgeType();
    yinit.regionid = 0;
    yinit.biospath = g_emulated_bios ? NULL : biospath;
    yinit.cdpath = cdpath;
    yinit.buppath = buppath;
    yinit.mpegpath = mpegpath;
    yinit.cartpath = cartpath;

    // Settings from YabaSanshiroConfig (JSON)
    yinit.videoformattype = g_yabaSanshiroConfig.GetVideoFormat();
    yinit.frameskip = g_yabaSanshiroConfig.GetFrameSkip();
    yinit.framelimit = g_yabaSanshiroConfig.GetFrameLimit();
    yinit.usethreads = 1;
    yinit.use_cpu_affinity = 1;
    yinit.skip_load = g_yabaSanshiroConfig.GetSkipLoad();
    yinit.video_filter_type = g_yabaSanshiroConfig.GetVideoFilter();
    yinit.polygon_generation_mode = g_yabaSanshiroConfig.GetPolygonMode();
    yinit.use_new_scsp = 1; // Always use new SCSP engine
    yinit.resolution_mode = g_yabaSanshiroConfig.GetResolutionMode();
    yinit.rotate_screen = g_yabaSanshiroConfig.GetRotateScreen();
    yinit.scsp_sync_count_per_frame = g_yabaSanshiroConfig.GetSCSPSync();
    yinit.extend_backup = 0;
    yinit.scsp_main_mode = 1;
    yinit.rbg_use_compute_shader = g_yabaSanshiroConfig.GetRBGComputeShader();
    yinit.rbg_resolution_mode = g_yabaSanshiroConfig.GetRBGResolutionMode();
    yinit.use_sh2_cache = g_yabaSanshiroConfig.GetSH2Cache();
    yinit.use_async_rendering = g_yabaSanshiroConfig.GetAsyncRendering();

    // Sync globals from config
    g_EnagleFPS = g_yabaSanshiroConfig.GetShowFPS();
    g_resolution_mode = g_yabaSanshiroConfig.GetResolutionMode();
    g_scsp_sync = g_yabaSanshiroConfig.GetSCSPSync();
    g_frame_skip = g_yabaSanshiroConfig.GetFrameSkip();

    if (g_frame_skip)
        EnableAutoFrameSkip();

    int res = YabauseInit(&yinit);
    if (res == -1)
    {
        LOG_ERROR("EMU", "YabauseInit failed");
        return -1;
    }

    // NOTE: OSDInit + OSDChangeCore moved to viewport setup block (needs GL context,
    // which is owned by the VDP thread after YabauseInit with YAB_ASYNC_RENDERING).
    LogStart();

    LOG_INFO("EMU", "Emulator initialized (bios=%s, cd=%s)", biospath, cdpath);
    return 0;
}

//==============================================================================
// Arg Parsing
//==============================================================================

static void ParseArgs(int argc, char **argv)
{
    std::string romArg;
    std::string biosArg;

    for (int i = 1; i < argc; i++)
    {
        if (!argv[i])
            continue;
        std::string arg = argv[i];
        if (arg == "ticoSetup")
            continue;
        if (romArg.empty())
            romArg = arg;
    }

    // ROM path
    if (!romArg.empty())
    {
        strncpy(cdpath, romArg.c_str(), sizeof(cdpath) - 1);
        cdpath[sizeof(cdpath) - 1] = '\0';
        LOG_INFO("ARGS", "ROM: %s", cdpath);
    }
    else
    {
        strncpy(cdpath, "./yabasanshiro/game.cue", sizeof(cdpath) - 1);
        LOG_WARN("ARGS", "No ROM argument. Using default: %s", cdpath);
    }

    // BIOS auto-detection
    const char *biosCandidates[] = {
        "sdmc:/tico/system/saturn/saturn_bios.bin",
        "sdmc:/tiicu/system/saturn/saturn_bios.bin",
        "./yabasanshiro/saturn_bios.bin",
    };
    bool biosFound = false;
    for (const char *candidate : biosCandidates)
    {
        struct stat st;
        if (stat(candidate, &st) == 0 && st.st_size > 0)
        {
            strncpy(biospath, candidate, sizeof(biospath) - 1);
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

    // Per-game backup path
    // Strip disc number so all discs of a multi-disc game share the same backup file
    // e.g. "Panzer Dragoon Saga (USA) (Disc 1)" → "Panzer Dragoon Saga (USA)"
    {
        std::string romStr(cdpath);
        size_t lastSlash = romStr.find_last_of("/\\");
        std::string romName = (lastSlash != std::string::npos) ? romStr.substr(lastSlash + 1) : romStr;
        size_t lastDot = romName.find_last_of(".");
        if (lastDot != std::string::npos)
            romName = romName.substr(0, lastDot);

        // Strip disc indicators: "(Disc 1)", "(Disk 2)", "(CD1)", etc.
        // Pattern: space or opening paren, followed by disc/disk/cd, number, optional closing paren
        {
            size_t pos;
            // Try "(Disc N)" or "(Disk N)"
            if ((pos = romName.find("(Disc ")) != std::string::npos ||
                (pos = romName.find("(Disk ")) != std::string::npos)
            {
                size_t end = romName.find(")", pos);
                if (end != std::string::npos)
                    romName.erase(pos, end - pos + 1);
            }
            // Try "(CD1)", "(CD2)", etc.
            else if ((pos = romName.find("(CD")) != std::string::npos)
            {
                size_t end = romName.find(")", pos);
                if (end != std::string::npos)
                    romName.erase(pos, end - pos + 1);
            }
            // Trim trailing whitespace after stripping
            while (!romName.empty() && romName.back() == ' ')
                romName.pop_back();
        }

        mkdir(TicoConfig::SAVES_PATH, 0777);
        std::string bup = std::string(TicoConfig::SAVES_PATH) + romName + ".bup";
        strncpy(buppath, bup.c_str(), sizeof(buppath) - 1);
        buppath[sizeof(buppath) - 1] = '\0';
        LOG_INFO("ARGS", "Backup: %s", buppath);
    }
}

//==============================================================================
// Input Handling
//==============================================================================

#define MAKE_PAD(a, b) ((a << 24) | (b))

/// Saturn port data for each player (Saturn has exactly 2 controller ports)
static PortData_struct *g_portData[MAX_PLAYERS] = {&PORTDATA1, &PORTDATA2};

/// Register all digital button bindings for a given player + controller pointer.
/// Must be called after PerPadAdd/Per3DPadAdd and after every PerPortReset.
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

/// Create all peripherals and register keys for all active players.
/// g_padMode[p] 0 = Standard Saturn Pad (digital only)
/// g_padMode[p] 1 = 3D Controller (analog + digital)
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

/// Re-initialize a single player's peripheral after a pad mode toggle.
/// Since PerPortReset clears ALL ports, we must re-init every player.
static void ReinitAfterToggle(int toggledPlayer)
{
    g_padMode[toggledPlayer] = (SanitizePadMode(g_padMode[toggledPlayer]) + 1) % 2;
    
    InitPeripherals();                              // Re-creates ALL pads and re-registers ALL keys
    g_padToast[toggledPlayer] = PAD_TOAST_DURATION; // Trigger toast
    
    const char* modeName = "Standard Pad";
    if (g_padMode[toggledPlayer] == 1) modeName = "3D Controller";
    
    LOG_INFO("INPUT", "Player %d pad mode → %s", toggledPlayer + 1, modeName);
}

static void HandleInput(int player, PadState *pad)
{
    u64 kDown = padGetButtons(pad);

    // Toggle Pad Mode: Minus + ZL (player 1 only toggles their own pad)
    if ((kDown & HidNpadButton_Minus) && (kDown & HidNpadButton_ZL))
    {
        if (g_debounce[player] == 0)
        {
            ReinitAfterToggle(player);
            g_debounce[player] = 30;
        }
    }
    if (g_debounce[player] > 0)
        g_debounce[player]--;

    void *padbits = g_padbits[player];

    // Face buttons
    if (kDown & HidNpadButton_A)
        PerKeyDown(MAKE_PAD(player, PERPAD_C));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_C));
    if (kDown & HidNpadButton_B)
        PerKeyDown(MAKE_PAD(player, PERPAD_B));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_B));
    if (kDown & HidNpadButton_X)
        PerKeyDown(MAKE_PAD(player, PERPAD_Y));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_Y));
    if (kDown & HidNpadButton_Y)
        PerKeyDown(MAKE_PAD(player, PERPAD_A));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_A));
    if (kDown & HidNpadButton_L)
        PerKeyDown(MAKE_PAD(player, PERPAD_X));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_X));
    if (kDown & HidNpadButton_R)
        PerKeyDown(MAKE_PAD(player, PERPAD_Z));
    else
        PerKeyUp(MAKE_PAD(player, PERPAD_Z));

    // D-Pad (always digital, both modes)
    HidAnalogStickState stick = padGetStickPos(pad, 0);

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

    // Left Stick behavior depends on pad mode
    if (g_padMode[player] == 1)
    {
        // 3D Controller: send real analog values
        PerAnalog_struct *analog = (PerAnalog_struct *)padbits;
        analog->analogbits[2] = (u8)((stick.x + 32768) >> 8);  // X: 0=left, 128=center, 255=right
        analog->analogbits[3] = (u8)((-stick.y + 32768) >> 8); // Y: 0=up, 128=center, 255=down
    }
    else
    {
        // Standard Pad: map left stick as additional d-pad input
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
    }

    // Start / Triggers
    if (g_padMode[player] == 2)
    {
        // Light Gun internal keys mapping
        if ((kDown & HidNpadButton_ZR) || (kDown & HidNpadButton_ZL))
            PerKeyDown(MAKE_PAD(player, PERGUN_TRIGGER));
        else
            PerKeyUp(MAKE_PAD(player, PERGUN_TRIGGER));
            
        if ((kDown & HidNpadButton_Plus) || (kDown & HidNpadButton_Minus))
            PerKeyDown(MAKE_PAD(player, PERGUN_START));
        else
            PerKeyUp(MAKE_PAD(player, PERGUN_START));

        // Light Gun movement mapping
        HidSixAxisSensorState sixaxis = {0};
        u64 style_set = padGetStyleSet(pad);
        
        if (style_set & HidNpadStyleTag_NpadHandheld)
            hidGetSixAxisSensorStates(g_sixaxis_handles[player][0], &sixaxis, 1);
        else if (style_set & HidNpadStyleTag_NpadFullKey)
            hidGetSixAxisSensorStates(g_sixaxis_handles[player][1], &sixaxis, 1);
        else if (style_set & HidNpadStyleTag_NpadJoyDual) {
            u64 attrib = padGetAttributes(pad);
            if (attrib & HidNpadAttribute_IsRightConnected)
                hidGetSixAxisSensorStates(g_sixaxis_handles[player][3], &sixaxis, 1); // Right Joy-Con preferred
            else if (attrib & HidNpadAttribute_IsLeftConnected)
                hidGetSixAxisSensorStates(g_sixaxis_handles[player][2], &sixaxis, 1);
        }
        
        // Multiplier to control sensitivity
        const float sensitivity = 150.0f; 
        
        // Use angular velocity (yaw/pitch) to determine relative movement on screen
        s32 dispx = (s32)(-sixaxis.angular_velocity.y * sensitivity); // Yaw controls X (inverted usually)
        s32 dispy = (s32)(sixaxis.angular_velocity.x * sensitivity);  // Pitch controls Y

        static int log_counter = 0;
        if (log_counter++ % 60 == 0) {
            FILE *fp = fopen("sdmc:/tiicu/debug/debug_core.txt", "a");
            if (fp) {
                fprintf(fp, "Sixaxis (style_set: %llu, attr: %llu): ang.y=%f, ang.x=%f | dispx=%d dispy=%d\n", 
                        style_set, padGetAttributes(pad),
                        sixaxis.angular_velocity.y, sixaxis.angular_velocity.x, dispx, dispy);
                fclose(fp);
            }
        }

        if (dispx != 0 || dispy != 0) {
            PerGunMove((PerGun_struct *)padbits, dispx, dispy);
        }

        // Recenter using stick click
        if ((kDown & HidNpadButton_StickL) || (kDown & HidNpadButton_StickR)) {
            PerGun_struct *gun = (PerGun_struct *)padbits;
            *(gun->gunbits+1) = 160 >> 8;
            *(gun->gunbits+2) = 160;
            *(gun->gunbits+3) = 112 >> 8;
            *(gun->gunbits+4) = 112;
        }
    }
    else
    {
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
}

//==============================================================================
// Dynamic Resolution (Handheld / Docked)
//==============================================================================

/// Recalculate viewport dimensions from current screen size.
/// The viewport always covers the full screen — the engine handles
/// aspect ratio correction internally (pillarbox/letterbox via ASPECT_RATE_MODE).
static void RecalculateViewport()
{
    g_viewportX = 0;
    g_viewportY = 0;
    g_viewportW = g_screenW;
    g_viewportH = g_screenH;
}

// Forward declaration (defined below UpdateScreenMode)
void ApplySaturnDisplaySettings(int displayMode, int displaySize);

/// Detect handheld/docked mode change and update nwindow crop, screen dimensions,
/// viewport, and ImGui display size. Following PlatformSwitch pattern.
/// Returns true if the mode actually changed.
static bool UpdateScreenMode(bool isPaused)
{
    u8 operationMode = appletGetOperationMode();
    if (operationMode == g_lastOperationMode)
        return false;

    // Update nwindow crop (no GL context needed)
    if (operationMode == AppletOperationMode_Handheld)
    {
        // Handheld: Crop 1080p surface to 720p BOTTOM-LEFT
        // OpenGL renders to bottom-left (Y=0), so show bottom 720 rows.
        // Top-Left indexing: Top = 1080 - 720 = 360, Bottom = 1080.
        nwindowSetCrop(nwindowGetDefault(), 0, 360, 1280, 1080);
        g_screenW = 1280;
        g_screenH = 720;
    }
    else
    {
        // Docked: Reset crop (full 1080p)
        nwindowSetCrop(nwindowGetDefault(), 0, 0, 1920, 1080);
        g_screenW = 1920;
        g_screenH = 1080;
    }
    g_lastOperationMode = operationMode;

    // Update ImGui display size
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)g_screenW, (float)g_screenH);

    // Re-apply the current display settings (display mode + display size)
    // for the new screen dimensions. ApplySaturnDisplaySettings recalculates
    // viewport, calls VIDCore->Resize, and clears the framebuffer.
    if (isPaused)
    {
        // Main thread already has GL context while paused
        ApplySaturnDisplaySettings(g_lastDisplayMode, g_lastDisplaySize);
    }
    else
    {
        if (yabsys.UseAsyncRendering)
        {
            // VDP thread has GL context — borrow it briefly
            VdpRevoke();
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        }

        ApplySaturnDisplaySettings(g_lastDisplayMode, g_lastDisplaySize);

        if (yabsys.UseAsyncRendering)
        {
            eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            VdpResume();
        }
    }

    LOG_INFO("DISPLAY", "Mode changed → %s (%dx%d, viewport=%d,%d %dx%d)",
             operationMode == AppletOperationMode_Handheld ? "Handheld" : "Docked",
             g_screenW, g_screenH, g_viewportX, g_viewportY, g_viewportW, g_viewportH);

    return true;
}

//==============================================================================
// In-Game Display Settings (called by TicoOverlay)
//==============================================================================

// Saturn base resolution — fixed at the most common mode (320×224).
// Games can dynamically change resolution (hi-res menus, PAL 256-line,
// interlaced FMVs) by writing to VDP2's TVMD register, but using a fixed
// base is the standard pragmatic approach: the engine's SetSaturnResolution
// handles the actual output, and integer scaling against 320×224 produces
// correct results for the vast majority of titles.
static constexpr int SATURN_BASE_W = 320;
static constexpr int SATURN_BASE_H = 224;

/// Called by TicoOverlay::ApplyDisplaySettings while the overlay is visible.
/// At that point the main thread holds the GL context (emulator paused via VdpRevoke).
///
/// @param displayMode SaturnDisplayMode (0=Integer, 1=Display)
/// @param displaySize SaturnDisplaySize
///        Integer: 4=1x, 5=2x, 6=3x, 7=4x, 8=Auto
///        Display: 0=Stretch, 1=4:3, 2=16:9, 3=Original
void ApplySaturnDisplaySettings(int displayMode, int displaySize)
{
    // Remember for re-applying on mode change (handheld ↔ docked)
    g_lastDisplayMode = displayMode;
    g_lastDisplaySize = displaySize;

    if (displayMode == 0) // Integer
    {
        // ── Integer Scaling ──────────────────────────────────────────────
        int scale;
        if (displaySize == 8) // Auto
        {
            int scaleX = g_screenW / SATURN_BASE_W;
            int scaleY = g_screenH / SATURN_BASE_H;
            scale = (scaleX < scaleY) ? scaleX : scaleY;
            if (scale < 1)
                scale = 1;
        }
        else
        {
            scale = displaySize - 3; // 4→1x, 5→2x, 6→3x, 7→4x
            if (scale < 1)
                scale = 1;
        }

        int scaledW = SATURN_BASE_W * scale;
        int scaledH = SATURN_BASE_H * scale;

        // Clamp to screen
        if (scaledW > g_screenW)
            scaledW = g_screenW;
        if (scaledH > g_screenH)
            scaledH = g_screenH;

        // Center on screen
        g_viewportX = (g_screenW - scaledW) / 2;
        g_viewportY = (g_screenH - scaledH) / 2;
        g_viewportW = scaledW;
        g_viewportH = scaledH;

        // ORIGINAL aspect mode — engine renders native pixels, no extra letterbox
        g_engineAspectMode = 0; // ORIGINAL
    }
    else // Display
    {
        // ── Display Mode (aspect-ratio based) ────────────────────────────
        // Full-screen viewport; engine handles pillarbox/letterbox internally
        g_viewportX = 0;
        g_viewportY = 0;
        g_viewportW = g_screenW;
        g_viewportH = g_screenH;

        // Map SaturnDisplaySize to engine ASPECT_RATE_MODE
        switch (displaySize)
        {
        case 0:
            g_engineAspectMode = 3;
            break; // Stretch → FULL
        case 1:
            g_engineAspectMode = 1;
            break; // 4:3 → _4_3
        case 2:
            g_engineAspectMode = 2;
            break; // 16:9 → _16_9
        case 3:
            g_engineAspectMode = 0;
            break; // Original → ORIGINAL
        default:
            g_engineAspectMode = 1;
            break; // fallback 4:3
        }
    }

    // Apply to the engine — we already hold the GL context (paused)
    VIDCore->Resize(g_viewportX, g_viewportY, g_viewportW, g_viewportH, 1, g_engineAspectMode);

    // Clear full framebuffer for clean borders
    glViewport(0, 0, g_screenW, g_screenH);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // Set the new viewport
    glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);

    LOG_INFO("DISPLAY", "ApplyDisplaySettings: mode=%d, size=%d → viewport=%d,%d %dx%d, aspectMode=%d",
             displayMode, displaySize, g_viewportX, g_viewportY, g_viewportW, g_viewportH, g_engineAspectMode);
}

//==============================================================================
// Save/Load State (called by TicoOverlay while paused)
//==============================================================================

/// Helper: build state file path for a given slot from the ROM path.
/// Returns e.g. "sdmc:/tico/states/saturn/GameName.state0"
static std::string BuildStatePath(int slot)
{
    std::string romStr(cdpath);
    size_t lastSlash = romStr.find_last_of("/\\");
    std::string romName = (lastSlash != std::string::npos) ? romStr.substr(lastSlash + 1) : romStr;
    size_t lastDot = romName.find_last_of(".");
    if (lastDot != std::string::npos)
        romName = romName.substr(0, lastDot);

    char slotStr[16];
    snprintf(slotStr, sizeof(slotStr), ".state%d", slot);

    return std::string(TicoConfig::STATES_PATH) + romName + slotStr;
}

/// Save emulator state to the given slot.
/// Called while the overlay is visible (main thread holds GL context, emulator paused).
bool SaturnSaveState(int slot)
{
    // Ensure states directory exists
    mkdir(TicoConfig::STATES_PATH, 0777);

    std::string path = BuildStatePath(slot);
    LOG_INFO("STATE", "Saving state to: %s", path.c_str());

    int result = YabSaveState(path.c_str());
    if (result == 0)
    {
        LOG_INFO("STATE", "State saved successfully (slot %d)", slot);
        return true;
    }
    else
    {
        LOG_ERROR("STATE", "Failed to save state (slot %d, result=%d)", slot, result);
        return false;
    }
}

/// Load emulator state from the given slot.
/// Called while the overlay is visible (main thread holds GL context, emulator paused).
bool SaturnLoadState(int slot)
{
    std::string path = BuildStatePath(slot);

    // Check file exists before attempting load
    struct stat st;
    if (stat(path.c_str(), &st) != 0)
    {
        LOG_WARN("STATE", "State file not found: %s", path.c_str());
        return false;
    }

    LOG_INFO("STATE", "Loading state from: %s", path.c_str());

    int result = YabLoadState(path.c_str());

    // Clear audio buffer after state load to prevent audio glitches.
    // This is especially important for early state loads where the SDL
    // audio buffer may contain stale data that causes silence or noise.
    SNDSDLClearBuffer();

    if (result == 0)
    {
        LOG_INFO("STATE", "State loaded successfully (slot %d)", slot);
        return true;
    }
    else
    {
        LOG_ERROR("STATE", "Failed to load state (slot %d, result=%d)", slot, result);
        return false;
    }
}

/// Check if a state file exists for the given slot.
bool SaturnStateExists(int slot)
{
    std::string path = BuildStatePath(slot);
    struct stat st;
    return (stat(path.c_str(), &st) == 0 && st.st_size > 0);
}

//==============================================================================
// Overlay Rendering (paused frame + ImGui)
//==============================================================================

static void RenderOverlay(TicoOverlay &overlay)
{
    // Clear full framebuffer black before overlay rendering
    glViewport(0, 0, g_screenW, g_screenH);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    // Draw captured game frame as background
    if (g_capturedFrameTex != 0)
    {
        ImDrawList *bg = ImGui::GetBackgroundDrawList();
        bg->AddImage(
            (ImTextureID)(intptr_t)g_capturedFrameTex,
            ImVec2(0, 0), ImVec2((float)g_screenW, (float)g_screenH),
            ImVec2(0.0f, 1.0f), // UV: flip vertically (GL origin is bottom-left)
            ImVec2(1.0f, 0.0f));
    }

    overlay.Render();
    ImGui::Render();

    glViewport(0, 0, g_screenW, g_screenH);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    eglSwapBuffers(s_display, s_surface);

    // Restore emulator viewport
    glViewport(g_viewportX, g_viewportY, g_viewportW, g_viewportH);
}

//==============================================================================
// Pause/Resume Transitions
//==============================================================================

static void OnPause()
{
    if (yabsys.UseAsyncRendering)
    {
        // Ask VDP thread to release GL context, then reclaim it on main thread
        VdpRevoke();
        eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    }
    // Capture front buffer into texture
    if (g_capturedFrameTex == 0)
        glGenTextures(1, &g_capturedFrameTex);
    glBindTexture(GL_TEXTURE_2D, g_capturedFrameTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glReadBuffer(GL_FRONT);
    glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 0, 0, g_screenW, g_screenH, 0);
    glReadBuffer(GL_BACK);
    glBindTexture(GL_TEXTURE_2D, 0);

    // Mute audio
    ScspMuteAudio(SCSP_MUTE_SYSTEM);
    SDL_PauseAudio(1);

    LOG_INFO("OVERLAY", "Paused — frame captured, audio muted");
}

static void OnResume()
{
    if (yabsys.UseAsyncRendering)
    {
        // Ensure GPU commands finish, unbind from main thread, hand back to VDP
        glFinish();
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        VdpResume();
    }
    else
    {
        // Non-async mode: ensure any pending GL commands from pause complete.
        // The main thread keeps the GL context, but we still need to sync.
        glFinish();
    }
    SDL_PauseAudio(0);
    ScspUnMuteAudio(SCSP_MUTE_SYSTEM);
    LOG_INFO("OVERLAY", "Resumed — audio unmuted, GL context returned to VDP thread");
}

//==============================================================================
// Cleanup
//==============================================================================

static void Cleanup()
{
    StopRAWorker();
    
    if (g_rcClient) {
        rc_client_destroy(g_rcClient);
        g_rcClient = nullptr;
    }
    
    if (g_trophySound) {
        Mix_FreeChunk(g_trophySound);
        g_trophySound = nullptr;
    }

    // If we're exiting while paused, resume first so the VDP thread
    // (if YAB_ASYNC_RENDERING) gets its GL context back and can process
    // the FINSH event during Vdp2DeInit cleanly.
    if (g_wasPaused)
    {
        OnResume();
        g_wasPaused = false;
    }

    // 1. Yabause (stops VDP thread which releases GL context via VDPEV_FINSH)
    YabauseDeInit();

    // 2. Reclaim GL context on main thread for cleanup.
    // - In async mode: VDP thread released it during DeInit, need to reclaim.
    // - In non-async mode: context should still be current, but verify to be safe.
    if (s_display != EGL_NO_DISPLAY && s_surface != EGL_NO_SURFACE && s_context != EGL_NO_CONTEXT)
    {
        if (eglGetCurrentContext() != s_context)
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
    }

    // 3. Delete captured frame texture (now safe — we have GL context)
    if (g_capturedFrameTex != 0)
    {
        glDeleteTextures(1, &g_capturedFrameTex);
        g_capturedFrameTex = 0;
    }

    // 4. ImGui (needs GL context to free resources)
    ImGui_ImplOpenGL3_Shutdown();
    ImGui::DestroyContext();

    // 5. EGL (last GPU operation before SDL teardown)
    DeinitEgl();

    // 6. SDL Audio
    Mix_CloseAudio();
    SDL_Quit();

    // 7. Switch subsystems
#ifdef __SWITCH__
    romfsExit();
    socketExit();
    appletUnlockExit();
#endif

    LOG_INFO("HOME", "Clean exit");
}

//==============================================================================
// Main
//==============================================================================

int main(int argc, char **argv)
{
    s_main_thread_id = pthread_self();
    // ---- Switch pre-init ----
#ifdef __SWITCH__
    appletLockExit();
    socketInitializeDefault();
#endif

    LOG_INFO("HOME", "YabaSanshiro starting (argc=%d)", argc);
    for (int i = 0; i < argc; i++)
        LOG_DEBUG("HOME", "  argv[%d]='%s'", i, argv[i] ? argv[i] : "(null)");

    // Guard: must be launched with "ticoSetup" argument (via tico launcher)
    {
        bool hasTicoSetup = false;
        for (int i = 1; i < argc; i++)
        {
            if (argv[i] && std::string(argv[i]) == "ticoSetup")
            {
                hasTicoSetup = true;
                break;
            }
        }
        if (!hasTicoSetup)
        {
            LOG_ERROR("HOME", "Missing 'ticoSetup' argument — exiting");
            appletUnlockExit();
            return 0;
        }
    }

    // Mount romfs (assets bundled in NRO)
    Result rc = romfsInit();
    bool romfsOk = R_SUCCEEDED(rc);
    if (!romfsOk)
        LOG_WARN("HOME", "romfsInit failed: 0x%x", rc);

    // Initialize SDL Audio for UI sounds (RetroAchievements)
    if (SDL_Init(SDL_INIT_AUDIO) < 0) {
        LOG_ERROR("HOME", "SDL_Init(AUDIO) failed: %s", SDL_GetError());
    } else {
        if (Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 1024) < 0) {
            LOG_ERROR("HOME", "Mix_OpenAudio failed: %s", Mix_GetError());
        }
    }

    // Initialize Translations
    TicoTranslationManager::Instance().Init();

    // ---- Parse args ----
    ParseArgs(argc, argv);

    // ---- Load Saturn config ----
    g_yabaSanshiroConfig.Load();
    LOG_INFO("HOME", "Saturn config loaded (resolution=%s, filter=%s, polygon=%s)",
             g_yabaSanshiroConfig.GetValue("resolution_mode").c_str(),
             g_yabaSanshiroConfig.GetValue("video_filter").c_str(),
             g_yabaSanshiroConfig.GetValue("polygon_mode").c_str());

    // ---- CPU boost ----
    apmSetPerformanceConfiguration(ApmPerformanceMode_Normal, 0x92220007);
    apmSetPerformanceConfiguration(ApmPerformanceMode_Boost, 0x92220008);

    // ---- Set native window to 1080p framebuffer ----
    // libnx defaults to 1280x720. We need 1920x1080 so that:
    //   - Docked: render at full 1920x1080
    //   - Handheld: render at 1280x720 in bottom-left, crop selects that region
    // Must be called BEFORE EGL init (which allocates buffers and locks dimensions).
    nwindowSetDimensions(nwindowGetDefault(), 1920, 1080);

    // ---- Detect initial display mode ----
    {
        u8 operationMode = appletGetOperationMode();
        if (operationMode == AppletOperationMode_Handheld)
        {
            // Crop to bottom-left 1280x720 of the 1080p buffer.
            // GL origin is bottom-left, so our 1280x720 rendering at (0,0)
            // maps to top-left rows 360..1080 → exactly the cropped region.
            nwindowSetCrop(nwindowGetDefault(), 0, 360, 1280, 1080);
            g_screenW = 1280;
            g_screenH = 720;
        }
        else
        {
            // Docked: full 1080p, no crop needed
            nwindowSetCrop(nwindowGetDefault(), 0, 0, 1920, 1080);
            g_screenW = 1920;
            g_screenH = 1080;
        }
        g_lastOperationMode = operationMode;
        LOG_INFO("DISPLAY", "Initial mode: %s (%dx%d)",
                 operationMode == AppletOperationMode_Handheld ? "Handheld" : "Docked",
                 g_screenW, g_screenH);
    }

    // ---- EGL ----
    if (!InitEgl(nwindowGetDefault()))
    {
        LOG_ERROR("HOME", "EGL init failed");
        return EXIT_FAILURE;
    }

    // ---- ImGui ----
    if (!InitImGui(romfsOk))
    {
        LOG_ERROR("HOME", "ImGui init failed");
        DeinitEgl();
        return EXIT_FAILURE;
    }

    // ---- Emulator ----
    if (InitEmulator() == -1)
    {
        LOG_ERROR("HOME", "Emulator init failed");
        ImGui_ImplOpenGL3_Shutdown();
        ImGui::DestroyContext();
        DeinitEgl();
        return EXIT_FAILURE;
    }

    // ---- Overlay ----
    // NOTE: The overlay object is created here but Init() is deferred to the
    // Viewport block below, where the main thread holds the GL context.
    // The constructor only loads config/settings (no GL calls).
    // LoadAvatar() and Init() (bolt icon) need GL context and are called later.
    TicoOverlay overlay;
    g_overlay = &overlay;

    // Extract game title from ROM path (strip extension, region tags, brackets)
    {
        std::string path(cdpath);

        overlay.SetCurrentCdPath(path);

        size_t slash = path.find_last_of("/\\");
        std::string filename = (slash != std::string::npos) ? path.substr(slash + 1) : path;
        std::string cleanTitle = TicoUtils::GetCleanTitle(filename);
        if (cleanTitle.empty())
        {
            // Fallback: just strip extension
            size_t dot = filename.find_last_of(".");
            cleanTitle = (dot != std::string::npos) ? filename.substr(0, dot) : filename;
        }
        overlay.SetGameTitle(cleanTitle);
    }

    // ---- Viewport ----
    {
        if (yabsys.UseAsyncRendering)
        {
            // With async rendering, the VDP thread now owns the GL context.
            // Borrow it briefly to set up the viewport, then return it.
            VdpRevoke(); // VDP thread releases GL context
            eglMakeCurrent(s_display, s_surface, s_surface, s_context);
        }

        // Init OSD/NanoVG here — needs GL context (NanoVG creates shaders/textures)
        // OSDInit(0);
        // OSDChangeCore(OSDCORE_NANOVG);

        // Initialize overlay GL resources (avatar texture, bolt icon) — must happen
        // while the main thread holds the GL context.
        overlay.Init();

        // Apply saved in-game display settings (display mode + integer scale).
        ApplySaturnDisplaySettings((int)overlay.GetDisplayMode(), (int)overlay.GetDisplaySize());

        if (yabsys.UseAsyncRendering)
        {
            eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            VdpResume(); // VDP thread reclaims GL context
        }
    }

    // ---- Peripherals & Controllers ----
    // Support up to 2 Switch controllers → 2 Saturn ports
    padConfigureInput(MAX_PLAYERS, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&g_pads[0]);             // Player 1: handheld or first wireless
    padInitialize(&g_pads[1], HidNpadIdType_No2); // Player 2: second wireless controller

    // Start with 1 player; detect second controller dynamically
    g_numPlayers = 1;

    // Load default controller mode from config (temporarily limited to Normal / 3D)
    g_padMode[0] = SanitizePadMode(g_yabaSanshiroConfig.GetControllerMode(0));
    g_padMode[1] = SanitizePadMode(g_yabaSanshiroConfig.GetControllerMode(1));

    LOG_INFO("INPUT", "Default controller mode: P1=%d, P2=%d",
             g_padMode[0], g_padMode[1]);

    // Initialize SixAxis Handles
    for (int p = 0; p < MAX_PLAYERS; p++) {
        HidNpadIdType npad_id = (p == 0) ? HidNpadIdType_Handheld : HidNpadIdType_No2;
        if (p == 0) {
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][0], 1, HidNpadIdType_Handheld, HidNpadStyleTag_NpadHandheld);
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][1], 1, HidNpadIdType_No1,      HidNpadStyleTag_NpadFullKey);
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][2], 2, HidNpadIdType_No1,      HidNpadStyleTag_NpadJoyDual);
        } else {
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][0], 1, HidNpadIdType_No2,      HidNpadStyleTag_NpadHandheld); // Should not happen
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][1], 1, HidNpadIdType_No2,      HidNpadStyleTag_NpadFullKey);
            hidGetSixAxisSensorHandles(&g_sixaxis_handles[p][2], 2, HidNpadIdType_No2,      HidNpadStyleTag_NpadJoyDual);
        }
        hidStartSixAxisSensor(g_sixaxis_handles[p][0]);
        hidStartSixAxisSensor(g_sixaxis_handles[p][1]);
        hidStartSixAxisSensor(g_sixaxis_handles[p][2]);
        hidStartSixAxisSensor(g_sixaxis_handles[p][3]);
    }

    InitPeripherals();

    // ---- RA Hook ----
    RAInit(cdpath);

    // ---- Main Loop ----
    LOG_INFO("HOME", "Entering main loop");

    bool shouldChainload = false;

    while (g_running)
    {
        if (!appletMainLoop())
        {
            g_running = false;
            break;
        }

        // Process RA Network Callbacks and State Machine immediately
        if (g_rcClient) {
            rc_client_do_frame(g_rcClient);
        }
        
        {
            std::lock_guard<std::mutex> lock(g_raCallbackMutex);
            for (auto& cb : g_raPendingCallbacks) {
                cb();
            }
            g_raPendingCallbacks.clear();
        }

        // Update all pads
        for (int p = 0; p < MAX_PLAYERS; p++)
            padUpdate(&g_pads[p]);

        // Detect second controller connect/disconnect
        {
            bool p2connected = padIsConnected(&g_pads[1]);
            if (p2connected && g_numPlayers < 2)
            {
                g_numPlayers = 2;
                InitPeripherals(); // Re-init both ports
                LOG_INFO("INPUT", "Player 2 connected");
            }
            else if (!p2connected && g_numPlayers > 1)
            {
                g_numPlayers = 1;
                InitPeripherals(); // Re-init with only port 1
                LOG_INFO("INPUT", "Player 2 disconnected");
            }
        }

        // Check for handheld/docked mode change
        UpdateScreenMode(g_wasPaused);

        // Overlay input (player 1 only, Minus+Plus toggle)
        overlay.HandleInput(&g_pads[0]);

        // Exit request
        if (overlay.ShouldExitGame())
        {
            shouldChainload = true;
            g_running = false;
            break;
        }

        // Pause/resume transitions
        bool isPaused = overlay.IsVisible();
        if (isPaused && !g_wasPaused)
            OnPause();
        if (!isPaused && g_wasPaused)
            OnResume();
        g_wasPaused = isPaused;

        // Paused: render overlay
        if (isPaused)
        {
            RenderOverlay(overlay);
            continue;
        }

        // Running: handle input for all active players + emulate
        for (int p = 0; p < g_numPlayers; p++)
            HandleInput(p, &g_pads[p]);
        YabauseExec();
    }

    // ---- Cleanup ----
    for (int p = 0; p < MAX_PLAYERS; p++) {
        hidStopSixAxisSensor(g_sixaxis_handles[p][0]);
        hidStopSixAxisSensor(g_sixaxis_handles[p][1]);
        hidStopSixAxisSensor(g_sixaxis_handles[p][2]);
        hidStopSixAxisSensor(g_sixaxis_handles[p][3]);
    }
    
    g_yabaSanshiroConfig.Unload();
    Cleanup();

    // Chainload back to tico launcher (if requested)
    if (shouldChainload)
    {
        const char *nextNro = "sdmc:/switch/tico.nro";

        struct stat buffer;
        if (stat(nextNro, &buffer) == 0)
        {
            char args[512];
            snprintf(args, sizeof(args), "%s --resume", nextNro);

            envSetNextLoad(nextNro, args);
            LOG_INFO("HOME", "Chainloading back to %s with args: %s", nextNro, args);
        }
        else
        {
            LOG_WARN("HOME", "Chainload target %s not found! Exiting normally.", nextNro);
        }

        remove("imgui.ini");
        LOG_INFO("HOME", "Deleted imgui.ini");
    }

    return 0;
}
