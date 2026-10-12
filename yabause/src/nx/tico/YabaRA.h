/// @file YabaRA.h
/// @brief RetroAchievements for YabaSanshiro: rc_client with the account tico
/// seals into the session, its HTTP worker, and the toasts the overlay draws.
#pragma once

#include <string>

#include "overlay/ra_alerts.h"

namespace YabaRA {

/// Logs in with the session's RetroAchievements account (or the older
/// accounts.jsonc) and identifies the disc. Does nothing when RA is off.
void Init(const std::string& disc_path);
void Shutdown();

/// Once per emulated frame, and while paused: rc_client's frame, and the
/// answers the HTTP worker brought back. Main thread.
void DoFrame();
/// While the emulator is paused (the quick menu is open): keeps the session
/// alive without processing a frame. Main thread.
void Idle();

bool Active();
/// True while rc_client runs the session in hardcore mode: no Load State,
/// cheats or slow motion.
bool Hardcore();

/// Hardcore only lets the game pause so often (pausing would help slow it
/// down): false while it can't yet, with how long until it can.
bool CanPause(int& seconds_remaining);

/// What the overlay draws the toasts from (on the drawing thread).
SwitchFrontend::RAAlerts::Source AlertSource();

} // namespace YabaRA
