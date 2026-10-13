/// @file YabaMenu.h
/// @brief The tico quick menu for YabaSanshiro: the shared overlay's callbacks
/// (states, cheats, discs, settings, the game list) and what its choices do.
///
/// The frontend pauses the emulator while the menu is open and keeps
/// presenting frames so the overlay draws; every call here is on the main
/// thread, with the emulator paused when it touches the core.
#pragma once

#include <switch.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace YabaMenu {

struct Host {
    /// Applies the settings that may change while the game runs (display
    /// mode and size, FPS counter, frame skip).
    std::function<void()> apply_live_settings;
    /// The game frame shown when the menu opened, RGBA top row first: the
    /// picture a saved state keeps.
    std::function<bool(std::vector<uint8_t>& rgba, int& width, int& height)> paused_frame;
    /// Pauses the game now and gives the main thread the renderer, for a
    /// screen that loads pictures as it opens (the main loop would only pause
    /// on its next turn).
    std::function<void()> pause;
};

/// Registers the overlay's callbacks. In library mode (no game) the menu is
/// the game list, which queues the chosen game.
void Init(const Host& host, bool library_mode);
void Shutdown();

void Open();
void Close();
bool IsOpen();

/// Feeds the pad (player 1) and runs what was chosen. The combo (Minus+Plus)
/// opens the menu while the game runs; it is passed in so the frontend can
/// tell the game's buttons from it.
void Update(u64 held, u64 pressed);
static constexpr u64 kToggleCombo = HidNpadButton_Minus | HidNpadButton_Plus;

/// Once the game shows: offers to continue from the auto save (tico's
/// General > Continue Last Game), unless this launch is a Restart.
void OfferResume();

/// Saves the game into the auto slot before it closes. The emulator must be
/// paused (the frontend holds the renderer).
void AutoSave();

/// A message the player answers before the game goes on (it is paused
/// meanwhile): Continue, or Exit Game.
void Notice(const std::string& message);

bool TakeExitRequest();
bool TakeRestartRequest();

/// Loads the game's cheats (sdmc:/tico/cheats/saturn/<game>.cht): every
/// cheat starts off, toggles last the session.
void LoadCheats();

/// Figures for the FPS counter.
void SetHud(float fps, int width, int height);

} // namespace YabaMenu
