/// @file TicoConfig.h
/// @brief Tico configuration constants for YabaSanshiro
#pragma once

namespace TicoConfig
{
    // Asset paths (romfs — bundled inside the NRO)
    constexpr const char *FONT_PATH = "romfs:/fonts/font.ttf";
    constexpr const char *BOLT_SVG_PATH = "romfs:/assets/bolt.svg";
    constexpr const char *SYSTEM_PATH = "sdmc:/tico/system/saturn/";
    constexpr const char *SAVES_PATH = "sdmc:/tico/saves/saturn/";
    constexpr const char *STATES_PATH = "sdmc:/tico/states/saturn/";

    // Window settings
    constexpr int WINDOW_WIDTH = 1280;
    constexpr int WINDOW_HEIGHT = 720;
    constexpr float FONT_SIZE = 32.0f;
}
