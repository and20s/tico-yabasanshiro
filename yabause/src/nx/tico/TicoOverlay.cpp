/// @file TicoOverlay.cpp
/// @brief Tico overlay UI for YabaSanshiro
/// No libretro dependency — uses Yabause API directly

#define IMGUI_DEFINE_MATH_OPERATORS
#include "TicoOverlay.h"
#include "TicoConfig.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <ctime>

#include "deps/nlohmann/json.hpp"
#include "TicoTranslationManager.h"
#include "TicoUtils.h"

// Vulkan-backed texture helpers (ImGui Vulkan backend)
#include "TicoVulkan.h"

#include <sys/stat.h>
#include <string>
#include <map>
#include <dirent.h>

#ifdef __SWITCH__
#include <switch.h>
#endif

// stb_image for avatar loading (implementation provided by nanovg.c)
#include "deps/stb/stb_image.h"

// Nanosvg for bolt icon
#define NANOSVG_IMPLEMENTATION
#include "deps/nanosvg/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "deps/nanosvg/nanosvgrast.h"

//==============================================================================
// UI Style Helpers
//==============================================================================

extern "C"
{
    int Cs2ForceCloseTray(int coreid, const char *cdpath);
    void YabauseResetButton(void);
}

namespace UIStyle
{

    inline void DrawTextWithShadow(ImDrawList *dl, ImVec2 pos, ImU32 color,
                                   const char *text, float shadowOffset = 1.5f)
    {
        ImU32 shadowColor = IM_COL32(0, 0, 0, 50);
        dl->AddText(ImVec2(pos.x + shadowOffset, pos.y + shadowOffset), shadowColor, text);
        dl->AddText(pos, color, text);
    }

    static void DrawSwitchButton(ImDrawList *dl, ImFont *font, float fontSize, ImVec2 center, float size, const char *symbol, float alpha, bool isDark)
    {
        ImU32 fillCol = IM_COL32(220, 220, 220, (int)(255 * alpha));
        ImU32 textCol = IM_COL32(40, 40, 40, (int)(255 * alpha));

        dl->AddCircleFilled(center, size * 0.5f, fillCol, 12);

        float symSize = fontSize * 0.75f;
        ImVec2 textSize = font->CalcTextSizeA(symSize, FLT_MAX, 0.0f, symbol);
        dl->AddText(font, symSize, center - (textSize * 0.5f), textCol, symbol);
    }

} // namespace UIStyle

//==============================================================================
// Construction
//==============================================================================

TicoOverlay::TicoOverlay()
{
    m_gameTitle = "Saturn";

    // Setup menu items
    m_menuItems.push_back({tr("emulator_save_state"), "S", QuickMenuItem::SaveState});
    m_menuItems.push_back({tr("emulator_load_state"), "L", QuickMenuItem::LoadState});
    m_menuItems.push_back({tr("emulator_settings"), "G", QuickMenuItem::Settings});
    m_menuItems.push_back({tr("emulator_exit_game"), "-", QuickMenuItem::ExitGame});

    // Load display config (dark mode, nickname visibility)
    LoadConfig();
    LoadGeneralConfig();

    // Load in-game display settings (display mode, integer scale)
    LoadCoreSettings();

    // Load nickname (no GL needed)
    LoadNickname();

#ifdef __SWITCH__
    psmInitialize();
#endif
}

TicoOverlay::~TicoOverlay()
{
#ifdef __SWITCH__
    psmExit();
#endif
    if (m_avatarTexture != 0)
    {
        TicoVulkan::DestroyTexture(m_avatarTexture);
        m_avatarTexture = 0;
    }
    if (m_boltTexture != 0)
    {
        TicoVulkan::DestroyTexture(m_boltTexture);
        m_boltTexture = 0;
    }
}

bool TicoOverlay::Init()
{
    // Load avatar texture (needs GL context)
    LoadAvatar();

    // Load bolt SVG as a GL texture for the charging indicator
    NSVGimage *svg = nsvgParseFromFile(TicoConfig::BOLT_SVG_PATH, "px", 96.0f);
    if (svg)
    {
        // Rasterize at a small size suitable for the status bar
        m_boltWidth = 16;
        m_boltHeight = (int)(16.0f * svg->height / svg->width);
        if (m_boltHeight < 1)
            m_boltHeight = 16;

        unsigned char *pixels = (unsigned char *)malloc(m_boltWidth * m_boltHeight * 4);
        if (pixels)
        {
            NSVGrasterizer *rast = nsvgCreateRasterizer();
            if (rast)
            {
                float scale = (float)m_boltWidth / svg->width;
                nsvgRasterize(rast, svg, 0, 0, scale, pixels, m_boltWidth, m_boltHeight, m_boltWidth * 4);
                nsvgDeleteRasterizer(rast);

                m_boltTexture = TicoVulkan::CreateTextureRGBA(pixels, (uint32_t)m_boltWidth, (uint32_t)m_boltHeight);
            }
            free(pixels);
        }
        nsvgDelete(svg);
    }
    return true;
}

void TicoOverlay::SetGameTitle(const std::string &title)
{
    m_gameTitle = title;
    // Trim
    m_gameTitle.erase(m_gameTitle.find_last_not_of(" \n\r\t") + 1);
    if (m_gameTitle.length() > 50)
    {
        m_gameTitle = m_gameTitle.substr(0, 47) + "...";
    }
}

void TicoOverlay::SetVisible(bool visible)
{
    if (visible && !m_visible)
    {
        m_visible = true;
        m_currentMenu = OverlayMenu::QuickMenu;
        m_animProgress = 0.0f;
        m_animating = true;
        m_selectedIndex = 0;
        m_settingsSelection = 0;

        // Reset scroll states
        m_discScrollY = 0.0f;
        m_discSelection = 0;

        ScanForDiscs();

        LoadConfig();        // Reload config on open
        LoadGeneralConfig(); // Reload hour format on open
    }
    else if (!visible && m_visible)
    {
        m_visible = false;
        m_currentMenu = OverlayMenu::None;
        m_animProgress = 0.0f;
    }
}

//==============================================================================
// Config Loading
//==============================================================================

void TicoOverlay::LoadConfig()
{
    const char *configPaths[] = {
        "sdmc:/tiicu/config/display.jsonc",
        "sdmc:/tico/config/display.jsonc",
    };

    m_isDarkMode = true;

    FILE *fp = nullptr;
    for (const char *path : configPaths)
    {
        fp = fopen(path, "rb");
        if (fp)
            break;
    }

    if (fp)
    {
        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        fseek(fp, 0, SEEK_SET);

        if (size > 0)
        {
            std::string content;
            content.resize(size);
            fread(&content[0], 1, size, fp);

            try
            {
                nlohmann::json j = nlohmann::json::parse(content, nullptr, false, true);
                if (!j.is_discarded())
                {
                    if (j.contains("dark_mode") && j["dark_mode"].is_boolean())
                    {
                        m_isDarkMode = j["dark_mode"].get<bool>();
                    }
                    else if (j.contains("darkMode") && j["darkMode"].is_boolean())
                    {
                        m_isDarkMode = j["darkMode"].get<bool>();
                    }
                }
            }
            catch (...)
            {
            }
        }
        fclose(fp);
    }
}

void TicoOverlay::LoadGeneralConfig()
{
    const char *configPaths[] = {
        "sdmc:/tiicu/config/general.jsonc",
        "sdmc:/tico/config/general.jsonc",
    };

    m_hourFormat = "24h";

    FILE *fp = nullptr;
    for (const char *path : configPaths)
    {
        fp = fopen(path, "rb");
        if (fp)
            break;
    }

    if (fp)
    {
        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        fseek(fp, 0, SEEK_SET);

        if (size > 0)
        {
            std::string content;
            content.resize(size);
            fread(&content[0], 1, size, fp);

            try
            {
                nlohmann::json j = nlohmann::json::parse(content, nullptr, false, true);
                if (!j.is_discarded())
                {
                    if (j.contains("hour_format") && j["hour_format"].is_string())
                    {
                        m_hourFormat = j["hour_format"].get<std::string>();
                    }
                }
            }
            catch (...)
            {
            }
        }
        fclose(fp);
    }
}

//==============================================================================
// Avatar & Nickname Loading
//==============================================================================

void TicoOverlay::LoadAvatar()
{
#ifdef __SWITCH__
    // Check for custom avatar
    const char *avatarPaths[] = {
        "sdmc:/tiicu/assets/avatar.jpg",
        "sdmc:/tico/assets/avatar.jpg",
    };

    for (const char *path : avatarPaths)
    {
        FILE *fp = fopen(path, "rb");
        if (fp)
        {
            fclose(fp);

            int width, height, channels;
            unsigned char *data = stbi_load(path, &width, &height, &channels, 4);
            if (data)
            {
                if (m_avatarTexture != 0)
                    TicoVulkan::DestroyTexture(m_avatarTexture);
                m_avatarTexture = TicoVulkan::CreateTextureRGBA(data, (uint32_t)width, (uint32_t)height);

                m_avatarWidth = width;
                m_avatarHeight = height;
                stbi_image_free(data);
                return;
            }
        }
    }

    // Fallback: Account Service
    Result rc = accountInitialize(AccountServiceType_Application);
    if (R_FAILED(rc))
        return;

    AccountUid uid = {0};
    bool found = false;

    if (R_SUCCEEDED(accountGetPreselectedUser(&uid)) && accountUidIsValid(&uid))
        found = true;
    if (!found && R_SUCCEEDED(accountGetLastOpenedUser(&uid)) && accountUidIsValid(&uid))
        found = true;

    if (!found)
    {
        s32 userCount = 0;
        if (R_SUCCEEDED(accountGetUserCount(&userCount)) && userCount > 0)
        {
            AccountUid uids[ACC_USER_LIST_SIZE];
            s32 actualTotal = 0;
            if (R_SUCCEEDED(accountListAllUsers(uids, ACC_USER_LIST_SIZE, &actualTotal)) && actualTotal > 0)
            {
                uid = uids[0];
                found = true;
            }
        }
    }

    if (found)
    {
        AccountProfile profile;
        if (R_SUCCEEDED(accountGetProfile(&profile, uid)))
        {
            u32 imageSize = 0;
            if (R_SUCCEEDED(accountProfileGetImageSize(&profile, &imageSize)) && imageSize > 0)
            {
                unsigned char *jpegBuf = (unsigned char *)malloc(imageSize);
                if (jpegBuf)
                {
                    u32 actualSize = 0;
                    if (R_SUCCEEDED(accountProfileLoadImage(&profile, jpegBuf, imageSize, &actualSize)))
                    {
                        int width, height, channels;
                        unsigned char *rgba = stbi_load_from_memory(jpegBuf, actualSize, &width, &height, &channels, 4);
                        if (rgba)
                        {
                            if (m_avatarTexture != 0)
                                TicoVulkan::DestroyTexture(m_avatarTexture);
                            m_avatarTexture = TicoVulkan::CreateTextureRGBA(rgba, (uint32_t)width, (uint32_t)height);
                            m_avatarWidth = width;
                            m_avatarHeight = height;
                            stbi_image_free(rgba);
                        }
                    }
                    free(jpegBuf);
                }
            }
            accountProfileClose(&profile);
        }
    }
    accountExit();
#endif
}

void TicoOverlay::LoadNickname()
{
#ifdef __SWITCH__
    // Check custom avatar paths first (if custom avatar loaded, use default name)
    const char *avatarPaths[] = {
        "sdmc:/tiicu/assets/avatar.jpg",
        "sdmc:/tico/assets/avatar.jpg",
    };

    for (const char *path : avatarPaths)
    {
        FILE *fp = fopen(path, "rb");
        if (fp)
        {
            fclose(fp);
            m_nickname = "Player 1";
            return;
        }
    }

    // Account Service nickname
    Result rc = accountInitialize(AccountServiceType_Application);
    if (R_FAILED(rc))
    {
        m_nickname = "Player 1";
        return;
    }

    AccountUid uid = {0};
    bool found = false;
    if (R_SUCCEEDED(accountGetPreselectedUser(&uid)) && accountUidIsValid(&uid))
        found = true;
    if (!found && R_SUCCEEDED(accountGetLastOpenedUser(&uid)) && accountUidIsValid(&uid))
        found = true;

    if (found)
    {
        AccountProfile profile;
        AccountProfileBase profileBase;
        if (R_SUCCEEDED(accountGetProfile(&profile, uid)))
        {
            if (R_SUCCEEDED(accountProfileGet(&profile, NULL, &profileBase)))
            {
                m_nickname = std::string(profileBase.nickname);
            }
            accountProfileClose(&profile);
        }
    }

    if (m_nickname.empty())
        m_nickname = "Player 1";
    accountExit();
#else
    m_nickname = "Player 1";
#endif
}

//==============================================================================
// Helpers
//==============================================================================

std::string TicoOverlay::GetTimeString() const
{
    std::time_t now = std::time(nullptr);
    std::tm *localTime = std::localtime(&now);
    char buf[16];
    if (m_hourFormat == "24h")
    {
        std::strftime(buf, sizeof(buf), "%H:%M", localTime);
    }
    else
    {
        std::strftime(buf, sizeof(buf), "%I:%M", localTime);
    }
    return std::string(buf);
}

int TicoOverlay::GetBatteryLevel() const
{
#ifdef __SWITCH__
    u32 level = 0;
    psmGetBatteryChargePercentage(&level);
    return (int)level;
#else
    return 100;
#endif
}

bool TicoOverlay::IsBatteryCharging() const
{
#ifdef __SWITCH__
    PsmChargerType chargerType;
    psmGetChargerType(&chargerType);
    return (chargerType != PsmChargerType_Unconnected);
#else
    return false;
#endif
}

//==============================================================================
// Input Handling (libnx PadState)
//==============================================================================

// Extern function defined in TicoMain.cpp — applies display settings to the
// engine (VIDCore->Resize + viewport) while the overlay is visible and the
// main thread holds the GL context.
extern void ApplySaturnDisplaySettings(int displayMode, int displaySize);

// Extern functions defined in TicoMain.cpp — save/load state while paused.
// The main thread holds the GL context during overlay visibility.
extern bool SaturnSaveState(int slot);
extern bool SaturnLoadState(int slot);
extern bool SaturnStateExists(int slot);

bool TicoOverlay::HandleInput(PadState *pad)
{
    if (!pad)
        return false;

    u64 kDown = padGetButtonsDown(pad);
    u64 kHeld = padGetButtons(pad);

    // Toggle overlay: Minus + Plus
    bool minusHeld = (kHeld & HidNpadButton_Minus) != 0;
    bool plusHeld = (kHeld & HidNpadButton_Plus) != 0;
    bool toggleCombo = minusHeld && plusHeld;

    if (toggleCombo && !m_prevMinusPlus)
    {
        m_prevMinusPlus = true;

        if (!m_visible)
        {
            SetVisible(true);
        }
        else if (m_currentMenu == OverlayMenu::Settings || m_currentMenu == OverlayMenu::SaveStates)
        {
            // Return to quick menu from submenus
            m_currentMenu = OverlayMenu::QuickMenu;
            m_animProgress = 0.4f; // Skip animation
        }
        else
        {
            SetVisible(false);
        }
        return true;
    }
    if (!toggleCombo)
        m_prevMinusPlus = false;

    // If overlay not visible, don't consume input
    if (!m_visible)
        return false;

    // Debounce
    uint64_t now = armGetSystemTick() / (armGetSystemTickFreq() / 1000); // ms
    bool debounced = (now - m_lastInputTime) > INPUT_DEBOUNCE_MS;

    // Navigation
    bool upPressed = (kDown & HidNpadButton_Up) != 0;
    bool downPressed = (kDown & HidNpadButton_Down) != 0;
    bool leftPressed = (kDown & HidNpadButton_Left) != 0;
    bool rightPressed = (kDown & HidNpadButton_Right) != 0;

    // Analog stick navigation
    HidAnalogStickState stickL = padGetStickPos(pad, 0);
    if (stickL.y > 16000 && debounced)
        upPressed = true;
    if (stickL.y < -16000 && debounced)
        downPressed = true;
    if (stickL.x < -16000 && debounced)
        leftPressed = true;
    if (stickL.x > 16000 && debounced)
        rightPressed = true;

    // Switch button layout: A = right (confirm on Switch), B = bottom (back on Switch)
    bool confirmPressed = (kDown & HidNpadButton_A) != 0;
    bool backPressed = (kDown & HidNpadButton_B) != 0;

    if (m_currentMenu == OverlayMenu::QuickMenu)
    {
        // Up
        if (upPressed && debounced)
        {
            m_lastInputTime = now;
            int numItems = (int)m_menuItems.size();
            m_selectedIndex = (m_selectedIndex - 1 + numItems) % numItems;
        }

        // Down
        if (downPressed && debounced)
        {
            m_lastInputTime = now;
            int numItems = (int)m_menuItems.size();
            m_selectedIndex = (m_selectedIndex + 1) % numItems;
        }

        // Confirm
        if (confirmPressed && debounced)
        {
            m_lastInputTime = now;

            if (m_selectedIndex >= 0 && m_selectedIndex < (int)m_menuItems.size())
            {
                switch (m_menuItems[m_selectedIndex].action)
                {
                case QuickMenuItem::SaveState:
                    m_isSaveMode = true;
                    m_saveStateSlot = 0;
                    m_currentMenu = OverlayMenu::SaveStates;
                    break;
                case QuickMenuItem::LoadState:
                    m_isSaveMode = false;
                    m_saveStateSlot = 0;
                    m_currentMenu = OverlayMenu::SaveStates;
                    break;
                case QuickMenuItem::Settings:
                    m_currentMenu = OverlayMenu::Settings;
                    m_settingsSelection = 0;
                    break;
                case QuickMenuItem::ExitGame:
                    m_exitRequested = true;
                    break;
                }
            }
        }

        // Back
        if (backPressed && debounced)
        {
            m_lastInputTime = now;
            SetVisible(false);
        }

        // Reset
        if ((kDown & HidNpadButton_Minus) != 0 && debounced)
        {
            m_lastInputTime = now;
            SetVisible(false);
            YabauseResetButton();
        }

        // Disc Swapping Check
        if ((kDown & HidNpadButton_X) != 0 && debounced && !m_discs.empty())
        {
            m_lastInputTime = now;
            m_currentMenu = OverlayMenu::DiscSelect;
            m_discSelection = 0;
        }
    }
    else if (m_currentMenu == OverlayMenu::DiscSelect)
    {
        int numChoices = m_discs.empty() ? 1 : m_discs.size();

        if (upPressed && debounced)
        {
            m_lastInputTime = now;
            m_discSelection--;
            if (m_discSelection < 0)
                m_discSelection = numChoices - 1;
        }
        else if (downPressed && debounced)
        {
            m_lastInputTime = now;
            m_discSelection++;
            if (m_discSelection >= numChoices)
                m_discSelection = 0;
        }
        else if (backPressed && debounced)
        {
            m_lastInputTime = now;
            m_currentMenu = OverlayMenu::QuickMenu;
        }
        else if (confirmPressed && debounced && !m_discs.empty())
        {
            m_lastInputTime = now;
            if (!m_discs.empty())
            {
                std::string newRomPath = m_discs[m_discSelection].romPath;
                
                FILE *fp = fopen(newRomPath.c_str(), "rb");
                if (!fp) {
                    m_gameTitle = tr("launcher_error_game_not_found");
                    return true;
                }
                fclose(fp);

                // Unpause to allow the emulator to process
                SetVisible(false);

                Cs2ForceCloseTray(1 /* CDCORE_ISO */, newRomPath.c_str());
                m_currentCdPath = newRomPath;

                std::string romName = newRomPath;
                size_t lastSlash = romName.find_last_of("/\\");
                if (lastSlash != std::string::npos)
                    romName = romName.substr(lastSlash + 1);
                size_t lastDot = romName.find_last_of('.');
                if (lastDot != std::string::npos)
                    romName = romName.substr(0, lastDot);

                std::string cleanTitle = TicoUtils::GetCleanTitle(romName);
                if (!cleanTitle.empty())
                    m_gameTitle = cleanTitle;
                else
                    m_gameTitle = romName;
            }
        }
    }
    else if (m_currentMenu == OverlayMenu::SaveStates)
    {
        const int numSlots = 4;

        // Up
        if (upPressed && debounced)
        {
            m_lastInputTime = now;
            m_saveStateSlot = (m_saveStateSlot - 1 + numSlots) % numSlots;
        }

        // Down
        if (downPressed && debounced)
        {
            m_lastInputTime = now;
            m_saveStateSlot = (m_saveStateSlot + 1) % numSlots;
        }

        // Confirm — save or load to selected slot
        if (confirmPressed && debounced)
        {
            m_lastInputTime = now;
            if (m_isSaveMode)
            {
                SaturnSaveState(m_saveStateSlot);
                // Return to quick menu after saving
                m_currentMenu = OverlayMenu::QuickMenu;
                m_animProgress = 0.4f;
            }
            else
            {
                SaturnLoadState(m_saveStateSlot);
                // Close overlay after loading (resume gameplay immediately)
                SetVisible(false);
                return true;
            }
        }

        // Back — return to quick menu
        if (backPressed && debounced)
        {
            m_lastInputTime = now;
            m_currentMenu = OverlayMenu::QuickMenu;
            m_animProgress = 0.4f;
        }
    }
    else if (m_currentMenu == OverlayMenu::Settings)
    {
        const int numSettingsItems = 2; // Display Mode, Size

        // Up
        if (upPressed && debounced)
        {
            m_lastInputTime = now;
            m_settingsSelection = (m_settingsSelection - 1 + numSettingsItems) % numSettingsItems;
        }

        // Down
        if (downPressed && debounced)
        {
            m_lastInputTime = now;
            m_settingsSelection = (m_settingsSelection + 1) % numSettingsItems;
        }

        // Left/Right — cycle settings values
        int direction = 0;
        if (leftPressed && debounced)
        {
            m_lastInputTime = now;
            direction = -1;
        }
        if (rightPressed && debounced)
        {
            m_lastInputTime = now;
            direction = 1;
        }

        if (direction != 0)
        {
            if (m_settingsSelection == 0)
            {
                // Display Mode: cycle Integer / Display
                int mode = (int)m_displayMode + direction;
                int count = (int)SaturnDisplayMode::COUNT;
                if (mode < 0)
                    mode = count - 1;
                if (mode >= count)
                    mode = 0;
                m_displayMode = (SaturnDisplayMode)mode;

                // Reset size to default for new mode
                if (m_displayMode == SaturnDisplayMode::Integer)
                    m_displaySize = SaturnDisplaySize::Auto;
                else
                    m_displaySize = SaturnDisplaySize::_4_3;

                ApplyDisplaySettings(true);
            }
            else if (m_settingsSelection == 1)
            {
                // Size: cycle within the subset for current mode
                if (m_displayMode == SaturnDisplayMode::Integer)
                {
                    // Integer sizes: 1x, 2x, 3x, 4x, Auto
                    static const SaturnDisplaySize intSizes[] = {
                        SaturnDisplaySize::_1x, SaturnDisplaySize::_2x,
                        SaturnDisplaySize::_3x, SaturnDisplaySize::_4x,
                        SaturnDisplaySize::Auto};
                    static const int intCount = 5;
                    int idx = 0;
                    for (int i = 0; i < intCount; i++)
                        if (intSizes[i] == m_displaySize)
                        {
                            idx = i;
                            break;
                        }
                    idx += direction;
                    if (idx < 0)
                        idx = intCount - 1;
                    if (idx >= intCount)
                        idx = 0;
                    m_displaySize = intSizes[idx];
                }
                else
                {
                    // Display sizes: Stretch, 4:3, 16:9, Original
                    static const SaturnDisplaySize dspSizes[] = {
                        SaturnDisplaySize::Stretch, SaturnDisplaySize::_4_3,
                        SaturnDisplaySize::_16_9, SaturnDisplaySize::Original};
                    static const int dspCount = 4;
                    int idx = 0;
                    for (int i = 0; i < dspCount; i++)
                        if (dspSizes[i] == m_displaySize)
                        {
                            idx = i;
                            break;
                        }
                    idx += direction;
                    if (idx < 0)
                        idx = dspCount - 1;
                    if (idx >= dspCount)
                        idx = 0;
                    m_displaySize = dspSizes[idx];
                }
                ApplyDisplaySettings(true);
            }
        }

        // Confirm acts like Right (cycle forward)
        if (confirmPressed && debounced)
        {
            m_lastInputTime = now;
            if (m_settingsSelection == 0)
            {
                int mode = ((int)m_displayMode + 1) % (int)SaturnDisplayMode::COUNT;
                m_displayMode = (SaturnDisplayMode)mode;
                if (m_displayMode == SaturnDisplayMode::Integer)
                    m_displaySize = SaturnDisplaySize::Auto;
                else
                    m_displaySize = SaturnDisplaySize::_4_3;
                ApplyDisplaySettings(true);
            }
            else if (m_settingsSelection == 1)
            {
                // Same as direction=+1
                if (m_displayMode == SaturnDisplayMode::Integer)
                {
                    static const SaturnDisplaySize intSizes[] = {
                        SaturnDisplaySize::_1x, SaturnDisplaySize::_2x,
                        SaturnDisplaySize::_3x, SaturnDisplaySize::_4x,
                        SaturnDisplaySize::Auto};
                    int idx = 0;
                    for (int i = 0; i < 5; i++)
                        if (intSizes[i] == m_displaySize)
                        {
                            idx = i;
                            break;
                        }
                    idx = (idx + 1) % 5;
                    m_displaySize = intSizes[idx];
                }
                else
                {
                    static const SaturnDisplaySize dspSizes[] = {
                        SaturnDisplaySize::Stretch, SaturnDisplaySize::_4_3,
                        SaturnDisplaySize::_16_9, SaturnDisplaySize::Original};
                    int idx = 0;
                    for (int i = 0; i < 4; i++)
                        if (dspSizes[i] == m_displaySize)
                        {
                            idx = i;
                            break;
                        }
                    idx = (idx + 1) % 4;
                    m_displaySize = dspSizes[idx];
                }
                ApplyDisplaySettings(true);
            }
        }

        // Back — return to quick menu
        if (backPressed && debounced)
        {
            m_lastInputTime = now;
            m_currentMenu = OverlayMenu::QuickMenu;
            m_animProgress = 0.4f; // Skip animation (already visible)
        }
    }

    return true; // Consume all input when overlay is visible
}

//==============================================================================
// Rendering
//==============================================================================

void TicoOverlay::Render()
{
    if (!m_visible)
        return;

    // Update animation
    float deltaTime = ImGui::GetIO().DeltaTime;
    if (m_animating)
    {
        m_animProgress += deltaTime;
        if (m_animProgress >= 0.4f)
        {
            m_animProgress = 0.4f;
            m_animating = false;
        }
    }

    // Disc Select Smooth Scrolling
    if (m_currentMenu == OverlayMenu::DiscSelect && !m_discs.empty())
    {
        float itemH = 64.0f;                                 // itemHeight
        int visibleItems = std::min((int)m_discs.size(), 5); // maxVisible
        float viewportH = visibleItems * itemH;
        float selectedTop = m_discSelection * itemH;
        float selectedBottom = selectedTop + itemH;

        if (selectedTop < m_discTargetScrollY)
            m_discTargetScrollY = selectedTop;
        if (selectedBottom > m_discTargetScrollY + viewportH)
            m_discTargetScrollY = selectedBottom - viewportH;

        float maxScroll = std::max(0.0f, (float)m_discs.size() * itemH - viewportH);
        m_discTargetScrollY = std::min(maxScroll, std::max(0.0f, m_discTargetScrollY));

        float speed = 12.0f;
        m_discScrollY += (m_discTargetScrollY - m_discScrollY) * std::min(1.0f, speed * deltaTime);
    }

    RenderBackground();
    RenderTitleCard();

    switch (m_currentMenu)
    {
    case OverlayMenu::QuickMenu:
        RenderQuickMenu();
        break;
    case OverlayMenu::SaveStates:
        RenderSaveStatesMenu();
        break;
    case OverlayMenu::Settings:
        RenderSettingsMenu();
        break;
    case OverlayMenu::DiscSelect:
        RenderDiscSelectMenu();
        break;
    default:
        break;
    }

    RenderHelpersBar();
    RenderSocialArea();
    RenderStatusBar();
}

//==============================================================================
// Background
//==============================================================================

void TicoOverlay::RenderBackground()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float ease = 1.0f - std::pow(1.0f - t, 3.0f);

    float baseAlphaVal = 200.0f;
    float maxAlphaVal = 250.0f;

    int baseAlpha = (int)(baseAlphaVal * ease);
    int maxAlpha = (int)(maxAlphaVal * ease);

    if (baseAlpha > 0)
    {
        float topH = displaySize.y * 0.20f;
        float botH = displaySize.y * 0.20f;
        float centerH = displaySize.y - topH - botH;

        ImU32 colMax = IM_COL32(0, 0, 0, maxAlpha);
        ImU32 colBase = IM_COL32(0, 0, 0, baseAlpha);

        dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(displaySize.x, topH),
                                    colMax, colMax, colBase, colBase);
        dl->AddRectFilled(ImVec2(0, topH), ImVec2(displaySize.x, topH + centerH), colBase);
        dl->AddRectFilledMultiColor(ImVec2(0, displaySize.y - botH), ImVec2(displaySize.x, displaySize.y),
                                    colBase, colBase, colMax, colMax);
    }
}

//==============================================================================
// Title Card
//==============================================================================

void TicoOverlay::RenderTitleCard()
{
    if (m_animProgress <= 0.0f)
        return;

    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    std::string titleStr = m_gameTitle;
    if (m_currentMenu == OverlayMenu::QuickMenu)
    {
        if (!m_discs.empty() && m_discSelection >= 0 && m_discSelection < (int)m_discs.size())
        {
            titleStr = m_gameTitle + " - " + m_discs[m_discSelection].displayName;
        }
    }
    else if (m_currentMenu == OverlayMenu::Settings)
        titleStr = tr("emulator_settings");
    else if (m_currentMenu == OverlayMenu::SaveStates)
        titleStr = m_isSaveMode ? tr("emulator_save_state") : tr("emulator_load_state");
    else if (m_currentMenu == OverlayMenu::DiscSelect)
        titleStr = tr("emulator_select_disc");

    const float TITLE_HEIGHT = 72.0f;
    const float AVAILABLE_TOP_SPACE = 110.0f;

    float cardWidth = displaySize.x * 0.4f;
    float cardX = (displaySize.x - cardWidth) * 0.5f;
    float cardY = (AVAILABLE_TOP_SPACE - TITLE_HEIGHT) * 0.5f;

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    float startY = -150.0f;
    float currentY = startY + (cardY - startY) * easeOut;

    ImU32 textColor = IM_COL32(200, 200, 200, 255);
    ImVec2 textSize = ImGui::CalcTextSize(titleStr.c_str());

    float textX = cardX + (cardWidth - textSize.x) * 0.5f;
    float textY = currentY + (TITLE_HEIGHT - textSize.y) * 0.5f;

    UIStyle::DrawTextWithShadow(dl, ImVec2(textX, textY), textColor, titleStr.c_str());
}

//==============================================================================
// Quick Menu
//==============================================================================

void TicoOverlay::RenderQuickMenu()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    const float menuWidth = 400.0f;
    const int numItems = (int)m_menuItems.size();
    const float itemHeight = 64.0f;
    const float contentHeight = numItems * itemHeight;

    ImVec2 menuSize(menuWidth, contentHeight);

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    float targetY = (displaySize.y - menuSize.y) / 2.0f;
    float startY = displaySize.y + 100.0f;
    float currentY = startY + (targetY - startY) * easeOut;

    ImVec2 menuPos((displaySize.x - menuSize.x) / 2, currentY);
    ImVec2 p0 = menuPos;
    ImVec2 p1 = ImVec2(menuPos.x + menuSize.x, menuPos.y + menuSize.y);

    const float cornerRadius = 16.0f;

    ImU32 containerColor;
    if (m_isDarkMode)
    {
        containerColor = IM_COL32(45, 45, 45, (int)(255 * easeOut));
    }
    else
    {
        containerColor = IM_COL32(242, 245, 248, (int)(255 * easeOut));
    }

    dl->AddRectFilled(p0, p1, containerColor, cornerRadius);

    ImFont *font = ImGui::GetFont();
    float baseFontSize = ImGui::GetFontSize();
    float smallFontSize = baseFontSize * 0.85f;

    for (int i = 0; i < numItems; i++)
    {
        bool isSelected = (m_selectedIndex == i);
        float itemY = menuPos.y + i * itemHeight;
        ImVec2 itemMin(menuPos.x, itemY);
        ImVec2 itemMax(menuPos.x + menuSize.x, itemY + itemHeight);

        if (isSelected)
        {
            ImDrawFlags corners = 0;
            float itemRadius = 0.0f;
            if (i == 0)
            {
                corners = ImDrawFlags_RoundCornersTop;
                itemRadius = cornerRadius;
            }
            if (i == numItems - 1)
            {
                corners |= ImDrawFlags_RoundCornersBottom;
                itemRadius = cornerRadius;
            }

            ImU32 selectedColor;
            if (m_isDarkMode)
            {
                selectedColor = IM_COL32(60, 60, 60, (int)(255 * easeOut));
            }
            else
            {
                selectedColor = IM_COL32(190, 195, 205, (int)(255 * easeOut));
            }

            dl->AddRectFilled(itemMin, itemMax, selectedColor, itemRadius, corners);
        }

        ImVec2 textSize = font->CalcTextSizeA(smallFontSize, FLT_MAX, 0.0f, m_menuItems[i].label.c_str());
        float textX = itemMin.x + 20.0f;
        float textY = itemMin.y + (itemHeight - textSize.y) / 2;

        ImU32 textColor;
        if (m_isDarkMode)
        {
            if (isSelected)
                textColor = IM_COL32(255, 255, 255, (int)(255 * easeOut));
            else
                textColor = IM_COL32(200, 200, 200, (int)(255 * easeOut));
        }
        else
        {
            if (isSelected)
                textColor = IM_COL32(60, 60, 70, (int)(255 * easeOut));
            else
                textColor = IM_COL32(90, 90, 100, (int)(255 * easeOut));
        }

        dl->AddText(font, smallFontSize, ImVec2(textX, textY), textColor, m_menuItems[i].label.c_str());
    }
}

//==============================================================================
// Save States Menu
//==============================================================================

void TicoOverlay::RenderSaveStatesMenu()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    const float menuWidth = 400.0f;
    const int numSlots = 4;
    const float itemHeight = 64.0f;
    const float contentHeight = numSlots * itemHeight;

    ImVec2 menuSize(menuWidth, contentHeight);

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    float targetY = (displaySize.y - menuSize.y) / 2.0f;
    float startY = displaySize.y + 100.0f;
    float currentY = startY + (targetY - startY) * easeOut;

    ImVec2 menuPos((displaySize.x - menuSize.x) / 2, currentY);
    ImVec2 p0 = menuPos;
    ImVec2 p1 = ImVec2(menuPos.x + menuSize.x, menuPos.y + menuSize.y);

    const float cornerRadius = 16.0f;

    ImU32 containerColor;
    if (m_isDarkMode)
        containerColor = IM_COL32(45, 45, 45, (int)(255 * easeOut));
    else
        containerColor = IM_COL32(242, 245, 248, (int)(255 * easeOut));

    dl->AddRectFilled(p0, p1, containerColor, cornerRadius);

    ImFont *font = ImGui::GetFont();
    float baseFontSize = ImGui::GetFontSize();
    float smallFontSize = baseFontSize * 0.85f;

    for (int i = 0; i < numSlots; i++)
    {
        bool isSelected = (m_saveStateSlot == i);
        float itemY = menuPos.y + i * itemHeight;
        ImVec2 itemMin(menuPos.x, itemY);
        ImVec2 itemMax(menuPos.x + menuSize.x, itemY + itemHeight);

        if (isSelected)
        {
            ImDrawFlags corners = 0;
            float itemRadius = 0.0f;
            if (i == 0)
            {
                corners = ImDrawFlags_RoundCornersTop;
                itemRadius = cornerRadius;
            }
            if (i == numSlots - 1)
            {
                corners |= ImDrawFlags_RoundCornersBottom;
                itemRadius = cornerRadius;
            }

            ImU32 selectedColor;
            if (m_isDarkMode)
                selectedColor = IM_COL32(60, 60, 60, (int)(255 * easeOut));
            else
                selectedColor = IM_COL32(190, 195, 205, (int)(255 * easeOut));

            dl->AddRectFilled(itemMin, itemMax, selectedColor, itemRadius, corners);
        }

        // Check if state file exists for this slot
        bool exists = SaturnStateExists(i);

        char slotText[64];
        snprintf(slotText, sizeof(slotText), tr("emulator_slot").c_str(), i + 1, exists ? tr("emulator_in_use").c_str() : tr("emulator_empty").c_str());

        ImVec2 sz = font->CalcTextSizeA(smallFontSize, FLT_MAX, 0.0f, slotText);
        float textX = itemMin.x + 20.0f;
        float textY = itemMin.y + (itemHeight - sz.y) / 2;

        ImU32 textColor;
        if (m_isDarkMode)
        {
            if (isSelected)
                textColor = IM_COL32(255, 255, 255, (int)(255 * easeOut));
            else
                textColor = IM_COL32(200, 200, 200, (int)(255 * easeOut));
        }
        else
        {
            if (isSelected)
                textColor = IM_COL32(60, 60, 70, (int)(255 * easeOut));
            else
                textColor = IM_COL32(90, 90, 100, (int)(255 * easeOut));
        }

        dl->AddText(font, smallFontSize, ImVec2(textX, textY), textColor, slotText);
    }
}

//==============================================================================
// Settings Menu
//==============================================================================

void TicoOverlay::RenderSettingsMenu()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    const float menuWidth = 400.0f;
    const int numItems = 2; // Display Mode, Size
    const float itemHeight = 64.0f;
    const float contentHeight = numItems * itemHeight;

    ImVec2 menuSize(menuWidth, contentHeight);

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    float targetY = (displaySize.y - menuSize.y) / 2.0f;
    float startY = displaySize.y + 100.0f;
    float currentY = startY + (targetY - startY) * easeOut;

    ImVec2 menuPos((displaySize.x - menuSize.x) / 2, currentY);
    ImVec2 p0 = menuPos;
    ImVec2 p1 = ImVec2(menuPos.x + menuSize.x, menuPos.y + menuSize.y);

    const float cornerRadius = 16.0f;

    ImU32 containerColor;
    if (m_isDarkMode)
        containerColor = IM_COL32(45, 45, 45, (int)(255 * easeOut));
    else
        containerColor = IM_COL32(242, 245, 248, (int)(255 * easeOut));

    dl->AddRectFilled(p0, p1, containerColor, cornerRadius);

    ImFont *font = ImGui::GetFont();
    float baseFontSize = ImGui::GetFontSize();
    float smallFontSize = baseFontSize * 0.85f;

    for (int i = 0; i < numItems; i++)
    {
        bool isSelected = (m_settingsSelection == i);
        float itemY = menuPos.y + i * itemHeight;
        ImVec2 itemMin(menuPos.x, itemY);
        ImVec2 itemMax(menuPos.x + menuSize.x, itemY + itemHeight);

        // Selection highlight
        if (isSelected)
        {
            ImDrawFlags corners = 0;
            float itemRadius = 0.0f;
            if (i == 0)
            {
                corners = ImDrawFlags_RoundCornersTop;
                itemRadius = cornerRadius;
            }
            if (i == numItems - 1)
            {
                corners |= ImDrawFlags_RoundCornersBottom;
                itemRadius = cornerRadius;
            }

            ImU32 selectedColor;
            if (m_isDarkMode)
                selectedColor = IM_COL32(60, 60, 60, (int)(255 * easeOut));
            else
                selectedColor = IM_COL32(190, 195, 205, (int)(255 * easeOut));

            dl->AddRectFilled(itemMin, itemMax, selectedColor, itemRadius, corners);
        }

        // Label + Value
        std::string label;
        std::string value;

        if (i == 0)
        {
            label = tr("emulator_display_mode");
            switch (m_displayMode)
            {
            case SaturnDisplayMode::Integer:
                value = tr("emulator_integer");
                break;
            case SaturnDisplayMode::Display:
                value = tr("emulator_display");
                break;
            default:
                value = tr("emulator_display");
                break;
            }
        }
        else if (i == 1)
        {
            label = tr("emulator_size");
            switch (m_displaySize)
            {
            case SaturnDisplaySize::Stretch:
                value = tr("emulator_stretch");
                break;
            case SaturnDisplaySize::_4_3:
                value = "4:3";
                break;
            case SaturnDisplaySize::_16_9:
                value = "16:9";
                break;
            case SaturnDisplaySize::Original:
                value = tr("emulator_original");
                break;
            case SaturnDisplaySize::_1x:
                value = "1x";
                break;
            case SaturnDisplaySize::_2x:
                value = "2x";
                break;
            case SaturnDisplaySize::_3x:
                value = "3x";
                break;
            case SaturnDisplaySize::_4x:
                value = "4x";
                break;
            case SaturnDisplaySize::Auto:
                value = tr("emulator_auto");
                break;
            default:
                value = "4:3";
                break;
            }
        }

        ImU32 textColor;
        if (m_isDarkMode)
        {
            if (isSelected)
                textColor = IM_COL32(255, 255, 255, (int)(255 * easeOut));
            else
                textColor = IM_COL32(200, 200, 200, (int)(255 * easeOut));
        }
        else
        {
            if (isSelected)
                textColor = IM_COL32(60, 60, 70, (int)(255 * easeOut));
            else
                textColor = IM_COL32(90, 90, 100, (int)(255 * easeOut));
        }

        // Draw label on left
        float textX = itemMin.x + 20.0f;
        ImVec2 labelSize = font->CalcTextSizeA(smallFontSize, FLT_MAX, 0.0f, label.c_str());
        float textY = itemMin.y + (itemHeight - labelSize.y) / 2;
        dl->AddText(font, smallFontSize, ImVec2(textX, textY), textColor, label.c_str());

        // Draw value on right (with space for arrows)
        ImVec2 valueSize = font->CalcTextSizeA(smallFontSize, FLT_MAX, 0.0f, value.c_str());
        float valueX = itemMax.x - valueSize.x - 40.0f;
        dl->AddText(font, smallFontSize, ImVec2(valueX, textY), textColor, value.c_str());

        // Draw triangle arrows when selected
        if (isSelected)
        {
            float arrowSize = 12.0f;
            float arrowY = itemMin.y + (itemHeight - arrowSize) / 2;

            // Left arrow
            float leftArrowX = valueX - arrowSize - 12.0f;
            ImVec2 la1 = ImVec2(leftArrowX, arrowY + arrowSize / 2);         // Tip
            ImVec2 la2 = ImVec2(leftArrowX + arrowSize, arrowY);             // Top right
            ImVec2 la3 = ImVec2(leftArrowX + arrowSize, arrowY + arrowSize); // Bottom right
            dl->AddTriangleFilled(la1, la2, la3, textColor);

            // Right arrow
            float rightArrowX = valueX + valueSize.x + 12.0f;
            ImVec2 ra1 = ImVec2(rightArrowX + arrowSize, arrowY + arrowSize / 2); // Tip
            ImVec2 ra2 = ImVec2(rightArrowX, arrowY);                             // Top left
            ImVec2 ra3 = ImVec2(rightArrowX, arrowY + arrowSize);                 // Bottom left
            dl->AddTriangleFilled(ra1, ra2, ra3, textColor);
        }
    }
}

//==============================================================================
// Settings Persistence
//==============================================================================

void TicoOverlay::LoadCoreSettings()
{
    // Read from the shared core config (same file the launcher uses)
#ifdef __SWITCH__
    std::string configPath = "sdmc:/tico/config/cores/yabasanshiro.jsonc";
#else
    std::string configPath = "tico/config/cores/yabasanshiro.jsonc";
#endif

    std::ifstream file(configPath);
    if (file.is_open())
    {
        try
        {
            auto j = nlohmann::json::parse(file, nullptr, false, true);
            file.close();

            if (!j.is_discarded())
            {
                // display_mode: "Integer" or "Display"
                if (j.contains("display_mode") && j["display_mode"].is_string())
                {
                    std::string v = j["display_mode"].get<std::string>();
                    if (v == "Integer")
                        m_displayMode = SaturnDisplayMode::Integer;
                    else
                        m_displayMode = SaturnDisplayMode::Display;
                }
                else
                    m_displayMode = SaturnDisplayMode::Display;

                // display_size: context-dependent string
                if (j.contains("display_size") && j["display_size"].is_string())
                {
                    std::string v = j["display_size"].get<std::string>();
                    if (v == "Stretch")
                        m_displaySize = SaturnDisplaySize::Stretch;
                    else if (v == "16:9")
                        m_displaySize = SaturnDisplaySize::_16_9;
                    else if (v == "Original")
                        m_displaySize = SaturnDisplaySize::Original;
                    else if (v == "1x")
                        m_displaySize = SaturnDisplaySize::_1x;
                    else if (v == "2x")
                        m_displaySize = SaturnDisplaySize::_2x;
                    else if (v == "3x")
                        m_displaySize = SaturnDisplaySize::_3x;
                    else if (v == "4x")
                        m_displaySize = SaturnDisplaySize::_4x;
                    else if (v == "Auto")
                        m_displaySize = SaturnDisplaySize::Auto;
                    else
                        m_displaySize = SaturnDisplaySize::_4_3;
                }
                else
                    m_displaySize = SaturnDisplaySize::_4_3;
            }
            else
            {
                m_displayMode = SaturnDisplayMode::Display;
                m_displaySize = SaturnDisplaySize::_4_3;
            }
        }
        catch (...)
        {
            m_displayMode = SaturnDisplayMode::Display;
            m_displaySize = SaturnDisplaySize::_4_3;
        }
    }
    else
    {
        m_displayMode = SaturnDisplayMode::Display;
        m_displaySize = SaturnDisplaySize::_4_3;
    }
}

void TicoOverlay::SaveCoreSettings()
{
    // Merge into the shared core config (same file the launcher uses)
#ifdef __SWITCH__
    std::string configPath = "sdmc:/tico/config/cores/yabasanshiro.jsonc";
#else
    std::string configPath = "tico/config/cores/yabasanshiro.jsonc";
#endif

    try
    {
        // Read existing config first so we only update our keys
        nlohmann::json j = nlohmann::json::object();
        {
            std::ifstream in(configPath);
            if (in.is_open())
            {
                auto parsed = nlohmann::json::parse(in, nullptr, false, true);
                in.close();
                if (!parsed.is_discarded())
                    j = parsed;
            }
        }

        // display_mode → string
        j["display_mode"] = (m_displayMode == SaturnDisplayMode::Integer) ? "Integer" : "Display";

        // display_size → string
        const char *sizeStr = "4:3";
        switch (m_displaySize)
        {
        case SaturnDisplaySize::Stretch:
            sizeStr = "Stretch";
            break;
        case SaturnDisplaySize::_4_3:
            sizeStr = "4:3";
            break;
        case SaturnDisplaySize::_16_9:
            sizeStr = "16:9";
            break;
        case SaturnDisplaySize::Original:
            sizeStr = "Original";
            break;
        case SaturnDisplaySize::_1x:
            sizeStr = "1x";
            break;
        case SaturnDisplaySize::_2x:
            sizeStr = "2x";
            break;
        case SaturnDisplaySize::_3x:
            sizeStr = "3x";
            break;
        case SaturnDisplaySize::_4x:
            sizeStr = "4x";
            break;
        case SaturnDisplaySize::Auto:
            sizeStr = "Auto";
            break;
        default:
            break;
        }
        j["display_size"] = sizeStr;

        std::ofstream out(configPath);
        if (out.is_open())
        {
            out << j.dump(4);
            out.close();
        }
    }
    catch (...)
    {
    }
}

void TicoOverlay::ApplyDisplaySettings(bool save)
{
    // Call the extern function in TicoMain.cpp to apply viewport/engine changes
    ApplySaturnDisplaySettings((int)m_displayMode, (int)m_displaySize);

    if (save)
        SaveCoreSettings();
}

//==============================================================================
// Helpers Bar
//==============================================================================

void TicoOverlay::RenderHelpersBar()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    const float BAR_HEIGHT = 48.0f;
    const float MARGIN_BOTTOM = 24.0f;
    const float PADDING = 16.0f;
    const float BUTTON_SIZE = 22.0f;
    const float ITEM_SPACING = 12.0f;

    ImFont *font = ImGui::GetFont();
    float fontSize = ImGui::GetFontSize() * 0.78f;

    struct Helper
    {
        const char *btn;
        std::string desc;
    };

    std::vector<Helper> helpers;

    if (m_currentMenu == OverlayMenu::QuickMenu)
    {
        helpers.push_back({"-", tr("emulator_reset")});
        if (!m_discs.empty())
        {
            helpers.push_back({"X", tr("emulator_disc")});
        }
    }
    else if (m_currentMenu == OverlayMenu::Settings)
    {
        helpers.push_back({"DPAD", tr("emulator_change")});
    }
    helpers.push_back({"B", tr("emulator_back")});
    helpers.push_back({"A", m_currentMenu == OverlayMenu::SaveStates
                                ? (m_isSaveMode ? tr("emulator_save_state") : tr("emulator_load_state"))
                                : tr("emulator_select")});

    float totalWidth = PADDING * 2;
    for (size_t i = 0; i < helpers.size(); i++)
    {
        float textW = font->CalcTextSizeA(fontSize, FLT_MAX, 0.0f, helpers[i].desc.c_str()).x;
        totalWidth += BUTTON_SIZE + 8.0f + textW;
        if (i < helpers.size() - 1)
            totalWidth += ITEM_SPACING;
    }

    float startOffset = 400.0f;
    float currentOffset = startOffset * (1.0f - easeOut);

    float barX = displaySize.x - totalWidth - 20.0f + currentOffset;
    float barY = displaySize.y - MARGIN_BOTTOM - BAR_HEIGHT;

    float cursorX = barX + PADDING;
    float centerY = barY + BAR_HEIGHT * 0.5f;

    for (const auto &h : helpers)
    {
        ImVec2 btnPos(cursorX + BUTTON_SIZE * 0.5f, centerY);
        UIStyle::DrawSwitchButton(dl, font, fontSize, btnPos, BUTTON_SIZE, h.btn, easeOut, true);

        cursorX += BUTTON_SIZE + 8.0f;

        ImVec2 textSize = font->CalcTextSizeA(fontSize, FLT_MAX, 0.0f, h.desc.c_str());
        float textY = centerY - textSize.y * 0.5f;

        ImU32 textColor = IM_COL32(200, 200, 200, (int)(255 * easeOut));
        dl->AddText(font, fontSize, ImVec2(cursorX, textY), textColor, h.desc.c_str());

        cursorX += textSize.x + ITEM_SPACING;
    }
}

//==============================================================================
// Social Area (Avatar + Nickname)
//==============================================================================

void TicoOverlay::RenderSocialArea()
{
    if (m_animProgress <= 0.0f)
        return;

    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float ease = 1.0f - std::pow(1.0f - t, 3.0f);

    if (ease < 0.01f)
        return;

    float startOffset = 200.0f;
    float currentOffset = startOffset * (1.0f - ease);

    float AVATAR_SIZE = 72.0f;
    float sideMargin = 32.0f;
    float topMargin = 32.0f;
    float barHeight = 50.0f;

    ImVec2 avatarCenter(sideMargin + AVATAR_SIZE * 0.5f - currentOffset,
                        topMargin + barHeight * 0.5f);

    float radius = AVATAR_SIZE * 0.5f;

    ImU32 baseCol;
    if (m_isDarkMode)
    {
        baseCol = IM_COL32(45, 45, 45, (int)(255 * ease));
    }
    else
    {
        baseCol = IM_COL32(245, 247, 250, (int)(200 * ease));
    }

    dl->AddCircleFilled(avatarCenter, radius, baseCol);

    if (m_avatarTexture != 0)
    {
        float imgRadius = radius - 4.0f;
        ImVec2 p_min = ImVec2(avatarCenter.x - imgRadius, avatarCenter.y - imgRadius);
        ImVec2 p_max = ImVec2(avatarCenter.x + imgRadius, avatarCenter.y + imgRadius);

        dl->AddImageRounded((ImTextureID)(intptr_t)m_avatarTexture, p_min, p_max,
                            ImVec2(0, 0), ImVec2(1, 1), IM_COL32_WHITE, imgRadius);
        dl->AddCircle(avatarCenter, imgRadius, IM_COL32(255, 255, 255, 60), 0, 1.0f);
    }
    else
    {
        float imgRadius = radius - 4.0f;
        dl->AddCircleFilled(avatarCenter, imgRadius, IM_COL32(200, 200, 210, 255));
    }
}

//==============================================================================
// Status Bar (Time + Battery)
//==============================================================================

void TicoOverlay::RenderStatusBar()
{
    if (m_animProgress <= 0.0f)
        return;

    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float ease = 1.0f - std::pow(1.0f - t, 3.0f);
    float alpha = ease;

    const float BAR_HEIGHT = 50.0f;
    const float TOP_MARGIN = 32.0f;
    const float SIDE_MARGIN = 32.0f;
    const float ITEM_SPACING = 20.0f;

    ImFont *font = ImGui::GetFont();
    float fontSize = ImGui::GetFontSize();

    // Time
    std::time_t now = std::time(nullptr);
    std::tm *localTime = std::localtime(&now);
    char timeStr[16];
    char periodStr[16];

    bool is24h = (m_hourFormat == "24h");

    float timeW = 0.0f;
    float periodFontSize = fontSize * 0.55f;
    float periodW = 0.0f;

    if (is24h)
    {
        std::strftime(timeStr, sizeof(timeStr), "%H:%M", localTime);
        timeW = font->CalcTextSizeA(fontSize, FLT_MAX, 0.0f, timeStr).x;
        periodStr[0] = '\0';
    }
    else
    {
        std::strftime(timeStr, sizeof(timeStr), "%I:%M", localTime);
        std::strftime(periodStr, sizeof(periodStr), "%p", localTime);
        timeW = font->CalcTextSizeA(fontSize, FLT_MAX, 0.0f, timeStr).x;
        periodW = font->CalcTextSizeA(periodFontSize, FLT_MAX, 0.0f, periodStr).x;
    }

    float totalWidth = timeW;
    if (!is24h)
        totalWidth += 4.0f + periodW;

    // Battery
    totalWidth += ITEM_SPACING + 34.0f;

    float PADDING = 20.0f;
    totalWidth += PADDING * 2;

    float offsetY = (1.0f - ease) * -20.0f;
    float barX = displaySize.x - totalWidth - SIDE_MARGIN;
    float barY = TOP_MARGIN + offsetY;

    ImU32 textColor = IM_COL32(200, 200, 200, (int)(255 * alpha));
    ImU32 iconColor = textColor;

    float cursorX = barX + PADDING;
    float centerY = barY + BAR_HEIGHT * 0.5f;

    // Draw Time
    ImVec2 timePos(cursorX, centerY - fontSize * 0.5f);
    dl->AddText(font, fontSize, timePos, textColor, timeStr);
    cursorX += timeW;

    if (!is24h)
    {
        cursorX += 4.0f;
        ImVec2 periodPos(cursorX, centerY - fontSize * 0.5f + (fontSize - periodFontSize) * 0.9f);
        dl->AddText(font, periodFontSize, periodPos, textColor, periodStr);
        cursorX += periodW;
    }

    // Draw Battery
    cursorX += ITEM_SPACING;

    float bodyWidth = 32.0f;
    float bodyHeight = 20.0f;
    float tipWidth = 4.0f;
    float tipHeight = 10.0f;

    ImVec2 batteryPos(cursorX, centerY - bodyHeight * 0.5f);
    ImVec2 bodyMin = batteryPos;
    ImVec2 bodyMax = bodyMin + ImVec2(bodyWidth, bodyHeight);

    // Stroke
    dl->AddRect(bodyMin, bodyMax, iconColor, 3.0f, 0, 2.0f);

    // Tip
    ImVec2 tipMin = ImVec2(bodyMax.x, batteryPos.y + (bodyHeight - tipHeight) * 0.5f);
    ImVec2 tipMax = tipMin + ImVec2(tipWidth, tipHeight);
    dl->AddRectFilled(tipMin, tipMax, iconColor, 2.0f, ImDrawFlags_RoundCornersRight);

    // Fill
    int battLevel = GetBatteryLevel();
    float pct = battLevel / 100.0f;
    if (pct > 1.0f)
        pct = 1.0f;
    if (pct < 0.0f)
        pct = 0.0f;

    float pad = 4.0f;
    float fillMaxW = bodyWidth - pad * 2;
    float currentFillW = fillMaxW * pct;
    if (currentFillW < 2.0f && pct > 0)
        currentFillW = 2.0f;

    if (currentFillW > 0)
    {
        ImVec2 fillMin = bodyMin + ImVec2(pad, pad);
        ImVec2 fillMax = fillMin + ImVec2(currentFillW, bodyHeight - pad * 2);
        dl->AddRectFilled(fillMin, fillMax, iconColor, 1.0f);
    }

    // Bolt icon if charging
    if (IsBatteryCharging())
    {
        float boltH = 14.0f;
        float boltW = 8.0f;
        float boltX = tipMax.x + 6.0f;
        float boltY = batteryPos.y + (bodyHeight - boltH) * 0.5f;

        if (m_boltTexture != 0)
        {
            // Render bolt SVG texture
            ImVec2 bMin(boltX, boltY);
            ImVec2 bMax(boltX + boltW, boltY + boltH);
            ImU32 tintColor = IM_COL32(235, 235, 235, (int)(255 * alpha));
            dl->AddImage((ImTextureID)(intptr_t)m_boltTexture, bMin, bMax,
                         ImVec2(0, 0), ImVec2(1, 1), tintColor);
        }
        else
        {
            // Fallback: simple bolt shape using triangles
            ImVec2 top(boltX + boltW * 0.6f, boltY);
            ImVec2 mid_left(boltX, boltY + boltH * 0.5f);
            ImVec2 mid_right(boltX + boltW, boltY + boltH * 0.45f);
            ImVec2 bottom(boltX + boltW * 0.4f, boltY + boltH);

            ImU32 boltColor = IM_COL32(235, 235, 235, (int)(255 * alpha));
            dl->AddTriangleFilled(top, mid_left, mid_right, boltColor);
            dl->AddTriangleFilled(mid_left, mid_right, bottom, boltColor);
        }
    }
}

//==============================================================================
// Disc Scanning & Menu
//==============================================================================

static std::string NormalizePath(const std::string &path)
{
    std::string result = path;
    for (char &c : result)
    {
        if (c == '\\')
            c = '/';
    }
    return result;
}

static int GetExtensionPriority(std::string ext)
{
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext == ".chd")
        return 1;
    if (ext == ".cue")
        return 2;
    if (ext == ".ccd")
        return 3;
    if (ext == ".iso")
        return 4;
    return 99;
}

void TicoOverlay::ScanForDiscs()
{
    m_discs.clear();

    std::string currentPath = m_currentCdPath;
    if (currentPath.empty())
        return;

    // Strip quotes if present (envSetNextLoad args might retain them)
    if (currentPath.front() == '"' && currentPath.back() == '"')
    {
        currentPath = currentPath.substr(1, currentPath.size() - 2);
    }

    currentPath = NormalizePath(currentPath);

    std::string dirname;
    std::string basename;
    size_t lastSlash = currentPath.find_last_of("/\\");
    if (lastSlash != std::string::npos)
    {
        dirname = currentPath.substr(0, lastSlash);
        basename = currentPath.substr(lastSlash + 1);
    }
    else
    {
        dirname = ".";
        basename = currentPath;
    }

    std::string lowerBase = basename;
    std::transform(lowerBase.begin(), lowerBase.end(), lowerBase.begin(), ::tolower);

    // M3U Parsing
    if (lowerBase.length() >= 4 && lowerBase.substr(lowerBase.length() - 4) == ".m3u") {
        FILE *fp = fopen(currentPath.c_str(), "r");
        if (fp) {
            char line[1024];
            int discIndex = 1;
            while (fgets(line, sizeof(line), fp)) {
                std::string strLine(line);
                strLine.erase(strLine.find_last_not_of(" \n\r\t") + 1);
                size_t startpos = strLine.find_first_not_of(" \n\r\t");
                if (std::string::npos != startpos) {
                    strLine = strLine.substr(startpos);
                } else {
                    strLine.clear();
                }

                if (strLine.empty() || strLine[0] == '#') continue;

                std::string discRelPath = dirname + "/" + strLine;
                std::string normalizedPath = NormalizePath(discRelPath);

                FILE *discCheck = fopen(normalizedPath.c_str(), "rb");
                if (!discCheck) {
                    // Missing file check, logic relies on swapping fail later.
                } else {
                    fclose(discCheck);
                }
                
                DiscEntry entry;
                entry.displayName = tr("emulator_disc") + " " + std::to_string(discIndex);
                entry.romPath = normalizedPath;
                m_discs.push_back(entry);
                discIndex++;
            }
            fclose(fp);
            return;
        }
    }

    std::string keyword;
    int currentDisc = 0;
    size_t patternPos = std::string::npos;
    const char *keywords[] = {"disc", "disk", "cd"};
    bool foundPat = false;
    for (const char *kw : keywords)
    {
        for (int n = 1; n <= 10; n++)
        {
            std::string pattern = std::string("(") + kw + " " + std::to_string(n) + ")";
            size_t pos = lowerBase.find(pattern);
            if (pos != std::string::npos)
            {
                keyword = kw;
                currentDisc = n;
                patternPos = pos;
                foundPat = true;
                break;
            }
        }
        if (foundPat)
            break;
    }

    if (!foundPat)
    {
        return;
    }

    size_t firstParen = lowerBase.find('(');
    std::string prefix = lowerBase;
    if (firstParen != std::string::npos)
    {
        prefix = lowerBase.substr(0, firstParen);
    }
    prefix.erase(prefix.find_last_not_of(" \n\r\t") + 1);

    std::vector<std::string> scanDirs;
    scanDirs.push_back(dirname);

    std::string lowerDir = dirname;
    std::transform(lowerDir.begin(), lowerDir.end(), lowerDir.begin(), ::tolower);
    bool isNested = false;
    for (const char *kw : keywords)
    {
        if (lowerDir.find(kw) != std::string::npos)
        {
            isNested = true;
            break;
        }
    }

    if (isNested)
    {
        scanDirs.push_back(dirname + "/..");
    }

    std::map<std::string, DiscEntry> bestDiscs;

    for (const auto &scanDir : scanDirs)
    {
        DIR *dir;
        struct dirent *ent;
        if ((dir = opendir(scanDir.c_str())) != NULL)
        {
            while ((ent = readdir(dir)) != NULL)
            {
                std::string filename = ent->d_name;
                if (filename == "." || filename == "..")
                    continue;

                std::string currentFileDir = scanDir;
                bool isSubDirItem = false;

                if (ent->d_type == DT_DIR)
                {
                    currentFileDir = scanDir + "/" + filename;
                    isSubDirItem = true;
                }

                DIR *subDir = NULL;
                struct dirent *subEnt = NULL;
                bool hasSubDir = false;

                if (isSubDirItem)
                {
                    subDir = opendir(currentFileDir.c_str());
                    if (subDir)
                    {
                        hasSubDir = true;
                        subEnt = readdir(subDir);
                    }
                    else
                    {
                        continue;
                    }
                }
                else
                {
                    subEnt = ent;
                }

                while (subEnt != NULL)
                {
                    std::string actualFilename = subEnt->d_name;
                    if (actualFilename == "." || actualFilename == "..")
                    {
                        if (hasSubDir)
                        {
                            subEnt = readdir(subDir);
                            continue;
                        }
                        else
                            break;
                    }

                    std::string lowerFilename = actualFilename;
                    std::transform(lowerFilename.begin(), lowerFilename.end(), lowerFilename.begin(), ::tolower);

                    std::string extFound = "";
                    size_t lastDot = lowerFilename.find_last_of('.');
                    if (lastDot != std::string::npos)
                    {
                        extFound = lowerFilename.substr(lastDot);
                    }

                    int priority = GetExtensionPriority(extFound);

                    // Strip extension for prefix comparison
                    std::string lowerNameNoExt = lowerFilename;
                    if (lastDot != std::string::npos) lowerNameNoExt = lowerFilename.substr(0, lastDot);

                    // Must start with prefix (not just contain it)
                    if (priority <= 4 && lowerNameNoExt.find(prefix) == 0)
                    {
                        // Reject if there are extra title words between prefix and first '('
                        // e.g. "metal gear solid - vr missions (usa)" has "- vr missions"
                        // which means it's a different game, not a disc
                        std::string afterPrefix = lowerNameNoExt.substr(prefix.size());
                        size_t parenPos = afterPrefix.find('(');
                        std::string beforeParen = (parenPos != std::string::npos)
                                                      ? afterPrefix.substr(0, parenPos)
                                                      : afterPrefix;
                        beforeParen.erase(beforeParen.find_last_not_of(" \t") + 1);
                        beforeParen.erase(0, beforeParen.find_first_not_of(" \t"));

                        if (beforeParen.empty())
                        {
                        bool foundDiscForFile = false;
                        for (const char *kw : keywords)
                        {
                            for (int n = 1; n <= 10; n++)
                            {
                                std::string pattern = std::string("(") + kw + " " + std::to_string(n) + ")";
                                if (lowerFilename.find(pattern) != std::string::npos)
                                {
                                    DiscEntry entry;
                                    entry.displayName = tr("emulator_disc") + " " + std::to_string(n);
                                    entry.romPath = NormalizePath(currentFileDir + "/" + actualFilename);

                                    if (bestDiscs.find(entry.displayName) == bestDiscs.end())
                                    {
                                        bestDiscs[entry.displayName] = entry;
                                    }
                                    else
                                    {
                                        std::string existingExt = "";
                                        std::string existingLower = bestDiscs[entry.displayName].romPath;
                                        std::transform(existingLower.begin(), existingLower.end(), existingLower.begin(), ::tolower);
                                        size_t extDot = existingLower.find_last_of('.');
                                        if (extDot != std::string::npos)
                                            existingExt = existingLower.substr(extDot);

                                        if (priority < GetExtensionPriority(existingExt))
                                        {
                                            bestDiscs[entry.displayName] = entry;
                                        }
                                    }
                                    foundDiscForFile = true;
                                    break;
                                }
                            }
                            if (foundDiscForFile)
                                break;
                        }
                        } // end if (beforeParen.empty())
                    }

                    if (hasSubDir)
                    {
                        subEnt = readdir(subDir);
                    }
                    else
                    {
                        break;
                    }
                }

                if (hasSubDir && subDir)
                {
                    closedir(subDir);
                }
            }
            closedir(dir);
        }
    }

    for (const auto &pair : bestDiscs)
    {
        m_discs.push_back(pair.second);
    }
}

void TicoOverlay::RenderDiscSelectMenu()
{
    ImVec2 displaySize = ImGui::GetIO().DisplaySize;
    ImDrawList *dl = ImGui::GetForegroundDrawList();

    const float menuWidth = 400.0f;
    int numItems = m_discs.empty() ? 1 : m_discs.size();
    const int maxVisible = 5;
    const float itemHeight = 64.0f;
    const float paddingY = 16.0f;

    float contentHeight = std::min(numItems, maxVisible) * itemHeight + (paddingY * 2.0f);
    ImVec2 menuSize(menuWidth, contentHeight);

    float t = m_animProgress / 0.4f;
    if (t > 1.0f)
        t = 1.0f;
    float easeOut = 1.0f - std::pow(1.0f - t, 3.0f);

    float targetY = (displaySize.y - menuSize.y) / 2.0f;
    float startY = displaySize.y + 100.0f;
    float currentY = startY + (targetY - startY) * easeOut;

    float startX = (displaySize.x - menuSize.x) / 2.0f;

    ImVec2 menuPos(startX, currentY);
    ImVec2 p0 = menuPos;
    ImVec2 p1 = ImVec2(menuPos.x + menuSize.x, menuPos.y + menuSize.y);

    const float cornerRadius = 16.0f;

    ImU32 containerColor;
    if (m_isDarkMode)
    {
        containerColor = IM_COL32(45, 45, 45, (int)(255 * easeOut));
    }
    else
    {
        containerColor = IM_COL32(242, 245, 248, (int)(255 * easeOut));
    }

    dl->AddRectFilled(p0, p1, containerColor, cornerRadius);

    ImFont *font = ImGui::GetFont();
    float baseFontSize = ImGui::GetFontSize();
    float smallFontSize = baseFontSize * 0.85f;

    ImVec2 clipP0(p0.x, p0.y + paddingY);
    ImVec2 clipP1(p1.x, p1.y - paddingY);
    dl->PushClipRect(clipP0, clipP1, true);

    for (int i = 0; i < numItems; i++)
    {
        bool isSelected = m_discs.empty() ? true : (m_discSelection == i);
        float itemY = clipP0.y + i * itemHeight - m_discScrollY;

        if (itemY + itemHeight < clipP0.y || itemY > clipP1.y)
            continue;

        float inset = 0.0f;
        ImVec2 itemMin(menuPos.x + inset, itemY);
        ImVec2 itemMax(menuPos.x + menuSize.x - inset, itemY + itemHeight);

        if (isSelected)
        {
            ImDrawFlags corners = 0;
            float itemRadius = 0.0f;

            ImU32 selectedColor;
            if (m_isDarkMode)
            {
                selectedColor = IM_COL32(60, 60, 60, (int)(255 * easeOut));
            }
            else
            {
                selectedColor = IM_COL32(190, 195, 205, (int)(255 * easeOut));
            }

            dl->AddRectFilled(itemMin, itemMax, selectedColor, itemRadius, corners);
        }

        std::string displayName = m_discs.empty() ? tr("emulator_no_discs") : m_discs[i].displayName;
        ImVec2 textSize = font->CalcTextSizeA(smallFontSize, FLT_MAX, 0.0f, displayName.c_str());
        float textX = itemMin.x + 20.0f;
        float textY = itemMin.y + (itemHeight - textSize.y) / 2;

        ImU32 textColor;
        if (m_isDarkMode)
        {
            if (isSelected)
                textColor = IM_COL32(255, 255, 255, (int)(255 * easeOut));
            else
                textColor = IM_COL32(200, 200, 200, (int)(255 * easeOut));
        }
        else
        {
            if (isSelected)
                textColor = IM_COL32(60, 60, 70, (int)(255 * easeOut));
            else
                textColor = IM_COL32(90, 90, 100, (int)(255 * easeOut));
        }

        dl->AddText(font, smallFontSize, ImVec2(textX, textY), textColor, displayName.c_str());
    }

    dl->PopClipRect();

    // Scroll shadow indicators
    bool needsScroll = numItems > maxVisible;
    if (needsScroll)
    {
        float maxScroll = (float)m_discs.size() * itemHeight - contentHeight + (paddingY * 2.0f);
        float shadowH = 20.0f;
        ImU32 shadowStart = IM_COL32(0, 0, 0, (int)(40 * easeOut));
        ImU32 shadowEnd = IM_COL32(0, 0, 0, 0);

        // Top shadow
        if (m_discScrollY > 1.0f)
        {
            float y1 = clipP0.y;
            float y2 = clipP0.y + shadowH;
            dl->AddRectFilledMultiColor(ImVec2(menuPos.x, y1), ImVec2(menuPos.x + menuSize.x, y2),
                                        shadowStart, shadowStart, shadowEnd, shadowEnd);
        }

        // Bottom shadow
        if (m_discScrollY < maxScroll - 1.0f)
        {
            float y1 = clipP1.y - shadowH;
            float y2 = clipP1.y;
            dl->AddRectFilledMultiColor(ImVec2(menuPos.x, y1), ImVec2(menuPos.x + menuSize.x, y2),
                                        shadowEnd, shadowEnd, shadowStart, shadowStart);
        }
    }
}
