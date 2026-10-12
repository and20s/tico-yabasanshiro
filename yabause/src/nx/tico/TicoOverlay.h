/// @file TicoOverlay.h
/// @brief Tico overlay UI for YabaSanshiro
#pragma once

#include "imgui.h"
#include <string>
#include <vector>
#include <memory>
#include <map>
#include <sys/stat.h>
#include <dirent.h>

#define GL_GLEXT_PROTOTYPES 1
#include <GL/gl.h>

#ifdef __SWITCH__
#include <switch.h>
#endif

/// @brief Disc Entry definition
struct DiscEntry
{
    std::string displayName;
    std::string romPath;
};

/// @brief Quick menu items
enum class QuickMenuItem
{
    SaveState,
    LoadState,
    Settings,
    ExitGame
};

/// @brief Overlay menu types
enum class OverlayMenu
{
    None,
    QuickMenu,
    SaveStates,
    Settings,
    DiscSelect
};

/// @brief Display mode for the emulator viewport
enum class SaturnDisplayMode
{
    Integer = 0, // Integer pixel scaling
    Display = 1, // Aspect-ratio based display
    COUNT = 2
};

/// @brief Display size (context-dependent on SaturnDisplayMode)
///   Integer → 1x, 2x, 3x, 4x, Auto
///   Display → Stretch, 4:3, 16:9, Original
enum class SaturnDisplaySize
{
    // Display sizes
    Stretch = 0,
    _4_3 = 1,
    _16_9 = 2,
    Original = 3,
    // Integer sizes
    _1x = 4,
    _2x = 5,
    _3x = 6,
    _4x = 7,
    Auto = 8
};

/// @brief Tico overlay UI
class TicoOverlay
{
public:
    TicoOverlay();
    ~TicoOverlay();

    /// @brief Initialize the overlay (load textures, etc.)
    bool Init();

    /// @brief Set the game title for display
    void SetGameTitle(const std::string &title);

    /// @brief Provide the current CD path for Disc Scanning
    void SetCurrentCdPath(const std::string &path) { m_currentCdPath = path; }

    /// @brief Handle input from libnx pad
    /// @param pad Pointer to PadState
    /// @return true if overlay consumed the input
    bool HandleInput(PadState *pad);

    /// @brief Render the overlay
    void Render();

    /// @brief Check if overlay is currently visible
    bool IsVisible() const { return m_visible; }

    /// @brief Check if user requested to exit the game
    bool ShouldExitGame() const { return m_exitRequested; }

    /// @brief Show/hide the overlay
    void SetVisible(bool visible);

    /// @brief Get current display mode setting
    SaturnDisplayMode GetDisplayMode() const { return m_displayMode; }

    /// @brief Get current display size setting
    SaturnDisplaySize GetDisplaySize() const { return m_displaySize; }

    /// @brief Check if dark mode is enabled
    bool IsDarkMode() const { return m_isDarkMode; }

private:
    // Rendering
    void RenderBackground();
    void RenderQuickMenu();
    void RenderSaveStatesMenu();
    void RenderSettingsMenu();
    void RenderStatusBar();
    void RenderSocialArea();
    void RenderTitleCard();
    void RenderHelpersBar();
    void RenderDiscSelectMenu();

    // Internal disc logic
    void ScanForDiscs();

    // State
    bool m_visible = false;
    bool m_exitRequested = false;
    bool m_isDarkMode = true;
    OverlayMenu m_currentMenu = OverlayMenu::QuickMenu;
    int m_selectedIndex = 0;

    // Animation
    float m_animProgress = 0.0f;
    bool m_animating = false;

    // Game info
    std::string m_gameTitle;
    std::string m_hourFormat = "24h";
    std::string m_currentCdPath;

    // Social area
    std::string m_nickname;
    GLuint m_avatarTexture = 0;
    int m_avatarWidth = 0;
    int m_avatarHeight = 0;

    // Bolt (charging) icon
    GLuint m_boltTexture = 0;
    int m_boltWidth = 0;
    int m_boltHeight = 0;

    // Input debounce
    bool m_prevMinusPlus = false;
    uint64_t m_lastInputTime = 0;
    static constexpr uint64_t INPUT_DEBOUNCE_MS = 200;

    // Quick menu items
    struct MenuItem
    {
        std::string label;
        std::string icon;
        QuickMenuItem action;
    };
    std::vector<MenuItem> m_menuItems;

    // Helpers
    void LoadConfig();
    void LoadGeneralConfig();
    void LoadAvatar();
    void LoadNickname();
    void LoadCoreSettings();
    void SaveCoreSettings();
    void ApplyDisplaySettings(bool save = true);
    std::string GetTimeString() const;
    int GetBatteryLevel() const;
    bool IsBatteryCharging() const;

    // Save states menu state
    int m_saveStateSlot = 0;
    bool m_isSaveMode = true;

    // Settings menu state
    int m_settingsSelection = 0;
    SaturnDisplayMode m_displayMode = SaturnDisplayMode::Display;
    SaturnDisplaySize m_displaySize = SaturnDisplaySize::_4_3;

    // Disc selection state
    int m_discSelection = 0;
    float m_discScrollY = 0.0f;
    float m_discTargetScrollY = 0.0f;
    std::vector<DiscEntry> m_discs;
};
