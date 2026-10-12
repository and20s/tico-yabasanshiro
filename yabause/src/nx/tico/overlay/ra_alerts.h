// Copyright 2026 Dan | ticoverse.com
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <functional>
#include <string>
#include <vector>

#include "imgui.h"

// RetroAchievements toasts (session start, unlocks, leaderboards), drawn over
// the game and the menu alike, with whichever renderer is active. The host
// owns the queue and the badge textures.
namespace SwitchFrontend::RAAlerts {

enum class Position {
    TopLeft = 0,
    TopRight,
    BottomLeft,
    BottomRight,
};

struct Notification {
    std::string title;
    std::string description;
    // a badge name, or "ra_icon" for the generic RetroAchievements icon
    std::string badge_name;
    ImTextureID texture = ImTextureID_Invalid;
    float timer = 0.0f;
    float duration = 4.0f;
    float slide_in = 0.4f;
    float slide_out = 0.4f;
};

struct Source {
    // the toasts on screen; Render advances and expires them. Only the
    // drawing thread touches them.
    std::vector<Notification>* notifications = nullptr;
    // moves toasts queued on other threads into `notifications`; called on
    // the drawing thread before anything else
    std::function<void()> collect;
    Position position = Position::TopRight;
    // a downloaded badge's texture, ImTextureID_Invalid while there is none
    std::function<ImTextureID(const std::string& badge_name)> badge_texture;
};

// True while there is a toast to draw, so the overlay draws a frame for it.
bool HasContent(const Source& source);

// Advances and draws the queued toasts, uploading the generic RA icon
// (romfs:/assets/ra.svg) the first time one needs it. Call while the overlay
// builds its frame.
void Render(const Source& source, ImDrawList* dl, ImVec2 display_size, float delta_time);

// Forgets the generic icon's texture; call when the overlay's backend goes away.
void ResetTextures();

} // namespace SwitchFrontend::RAAlerts
