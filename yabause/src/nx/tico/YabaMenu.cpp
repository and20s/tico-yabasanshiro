/// @file YabaMenu.cpp
/// @brief The tico quick menu for YabaSanshiro (see YabaMenu.h).

#include "YabaMenu.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fstream>
#include <map>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "TicoLogger.h"
#include "TicoSafeFile.h"
#include "UsbStorage.h"
#include "YabaRA.h"
#include "overlay/imgui_overlay.h"
#include "overlay/overlay_ui.h"
#include "overlay/tico_config.h"
#include "overlay/translation_manager.h"
#include "tico_entry.h"
#include "tico_library.h"

#include "deps/stb/stb_image.h" // stbi_load: nanovg.c has the implementation
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#include "deps/stb/stb_image_write.h"

extern "C" {
#include "cdbase.h"
#include "cheat.h"
#include "cs2.h"
#include "memory.h"
#include "scsp.h"
#include "sndsdl.h"
#include "yabause.h"
}

namespace OverlayUI = SwitchFrontend::OverlayUI;
namespace ImGuiOverlay = SwitchFrontend::ImGuiOverlay;
namespace TicoConfig = SwitchFrontend::TicoConfig;

namespace YabaMenu {
namespace {

constexpr int kSlotCount = 6; // 1-5 the player's, 6 the auto save
constexpr int kAutoSlot = OverlayUI::kAutoStateSlot;
constexpr int kStateBackups = 2;
constexpr u64 kRepeatDelayMs = 350;
constexpr u64 kRepeatRateMs = 80;
// A state's picture fits in this box, as in tico's other cores
constexpr int kPreviewMaxWidth = 256;
constexpr int kPreviewMaxHeight = 192;
constexpr uint32_t kPreviewMagic = 0x4D485459; // "YTHM", the raw pictures of earlier builds

// The overlay's message for key in tico's language, or `fallback` when the
// language files do not have it.
std::string Tr(const char* key, const char* fallback) {
    SwitchFrontend::OverlayTranslation::TranslationManager::Instance().Init();
    const std::string text = SwitchFrontend::OverlayTranslation::tr(key);
    return text.empty() || text == key ? fallback : text;
}

template <typename T>
std::string TrFormat(const char* key, const char* fallback, T value) {
    const std::string format = Tr(key, fallback);
    char text[256];
    std::snprintf(text, sizeof(text), format.c_str(), value);
    return text;
}

u64 NowMs() {
    return armTicksToNs(armGetSystemTick()) / 1000000;
}

bool IsFile(const std::string& path) {
    struct stat status;
    return stat(path.c_str(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size > 0;
}

std::string Trim(const std::string& text) {
    const std::size_t first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos)
        return {};
    return text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
}

bool PromptKeyboard(const char* header, const char* guide, const std::string& initial,
                    std::size_t max_length, bool multiline, std::string& output) {
    SwkbdConfig keyboard;
    if (R_FAILED(swkbdCreate(&keyboard, 0)))
        return false;
    swkbdConfigMakePresetDefault(&keyboard);
    swkbdConfigSetHeaderText(&keyboard, header);
    if (guide)
        swkbdConfigSetGuideText(&keyboard, guide);
    if (!initial.empty())
        swkbdConfigSetInitialText(&keyboard, initial.c_str());
    swkbdConfigSetStringLenMax(&keyboard, static_cast<u32>(max_length));
    swkbdConfigSetReturnButtonFlag(&keyboard, multiline ? 1 : 0);
    std::vector<char> text(max_length + 1);
    const Result result = swkbdShow(&keyboard, text.data(), text.size());
    swkbdClose(&keyboard);
    if (R_FAILED(result))
        return false;
    output = text.data();
    return true;
}

// ---------------------------------------------------------------------------
// Cheats: Saturn Action Replay codes ("XXXXXXXX YYYY", one per address)

struct Cheat {
    std::string name;
    std::vector<std::string> codes; // "%08X %04X", as CheatAddARCode reads them
    bool enabled = false;
};

// Codes as hex: an 8-digit address, then a 4-digit value, separated by
// anything (or written together as 12 digits). Empty if malformed.
std::vector<std::string> ParseCodes(const std::string& text) {
    std::string digits;
    for (const char c : text) {
        if (std::isxdigit(static_cast<unsigned char>(c)))
            digits += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        else if (c == 'x' || c == 'X') {
            if (!digits.empty() && digits.back() == '0')
                digits.pop_back(); // a 0x prefix
        }
    }
    if (digits.empty() || digits.size() % 12 != 0)
        return {};
    std::vector<std::string> codes;
    for (std::size_t i = 0; i < digits.size(); i += 12)
        codes.push_back(digits.substr(i, 8) + " " + digits.substr(i + 8, 4));
    return codes;
}

// The game's cheats in tico's folder, sdmc:/tico/cheats/saturn/<game>.cht
// (RetroArch: cheatN_desc / cheatN_code) or <game>.cheats ("# Name", then the
// codes), as the other tico cores read them.
std::vector<Cheat> ReadTicoCheats(const std::string& stem) {
    std::vector<Cheat> cheats;
    if (stem.empty())
        return cheats;
    const std::string base = "sdmc:/tico/cheats/" TICO_CORE_SLUG "/" + stem;
    std::map<int, std::pair<std::string, std::string>> by_index;
    std::ifstream cht(base + ".cht");
    std::string line;
    while (cht.is_open() && std::getline(cht, line)) {
        const std::size_t equals = line.find('=');
        if (equals == std::string::npos)
            continue;
        const std::string key = Trim(line.substr(0, equals));
        std::string value = Trim(line.substr(equals + 1));
        if (value.size() >= 2 && value.front() == '"' && value.back() == '"')
            value = value.substr(1, value.size() - 2);
        int index = -1;
        char field[16] = {0};
        if (std::sscanf(key.c_str(), "cheat%d_%15s", &index, field) != 2 || index < 0)
            continue;
        if (!std::strcmp(field, "desc"))
            by_index[index].first = value;
        else if (!std::strcmp(field, "code"))
            by_index[index].second += " " + value;
    }
    for (auto& [index, entry] : by_index) {
        Cheat cheat;
        cheat.name = entry.first.empty()
                         ? TrFormat("yabasanshiro_cheat_number", "Cheat %d", index + 1)
                         : entry.first;
        std::string codes = entry.second;
        std::replace(codes.begin(), codes.end(), '+', ' ');
        cheat.codes = ParseCodes(codes);
        if (!cheat.codes.empty())
            cheats.push_back(std::move(cheat));
    }
    std::ifstream simple(base + ".cheats");
    Cheat current;
    std::string codes;
    auto finish = [&] {
        current.codes = ParseCodes(codes);
        if (!current.codes.empty())
            cheats.push_back(current);
        current = {};
        codes.clear();
    };
    bool started = false;
    while (simple.is_open() && std::getline(simple, line)) {
        const std::string text = Trim(line);
        if (text.empty() || text[0] == '!')
            continue;
        if (text[0] == '#') {
            if (started)
                finish();
            current.name = Trim(text.substr(1));
            started = true;
            continue;
        }
        if (!started) {
            current.name = TrFormat("yabasanshiro_cheat_number", "Cheat %d", 1);
            started = true;
        }
        codes += " " + text;
    }
    if (started)
        finish();
    return cheats;
}

// ---------------------------------------------------------------------------
// Discs: the other "(Disc N)" images of the game, beside it

struct Disc {
    std::string name;
    std::string path;
};

std::string DiscBase(const std::string& name, int& number) {
    number = 0;
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    for (const char* marker : {"(disc ", "(disk ", "(cd"}) {
        const std::size_t at = lower.find(marker);
        if (at == std::string::npos)
            continue;
        const std::size_t close = lower.find(')', at);
        if (close == std::string::npos)
            continue;
        number = std::atoi(lower.c_str() + at + std::strlen(marker));
        std::string base = name.substr(0, at) + name.substr(close + 1);
        const std::size_t dot = base.find_last_of('.');
        return dot == std::string::npos ? base : base.substr(0, dot);
    }
    return {};
}

std::vector<Disc> FindDiscs(const std::string& disc_path) {
    std::vector<Disc> discs;
    const std::size_t slash = disc_path.find_last_of('/');
    if (slash == std::string::npos)
        return discs;
    const std::string folder = disc_path.substr(0, slash + 1);
    const std::string own = disc_path.substr(slash + 1);
    int own_number = 0;
    const std::string base = DiscBase(own, own_number);
    if (base.empty())
        return discs;
    const std::string extension = own.substr(own.find_last_of('.'));
    std::map<int, Disc> by_number;
    if (DIR* dir = opendir(folder.c_str())) {
        while (struct dirent* entry = readdir(dir)) {
            const std::string name = entry->d_name;
            if (name.size() < extension.size() ||
                strcasecmp(name.c_str() + name.size() - extension.size(), extension.c_str()))
                continue;
            int number = 0;
            if (DiscBase(name, number) == base && number > 0)
                by_number[number] = {TrFormat("yabasanshiro_disc_number", "Disc %d", number),
                                     folder + name};
        }
        closedir(dir);
    }
    for (auto& [number, disc] : by_number)
        discs.push_back(disc);
    return discs;
}

// ---------------------------------------------------------------------------
// Players: what is plugged into the Saturn's two ports, or into the multitap

// The 6Player adaptor (Settings > Input): players 1-6 on port 1, 7-8 on port 2
bool Multitap() {
    return TicoConfig::GetConfigValue("multitap", "disabled") == "enabled";
}
constexpr int kMultitapPlayers = 8; // the Switch's controllers

std::vector<std::string> ControllerNames() {
    auto name = [](u32 style) -> std::string {
        const char* key = "emulator_pad_other";
        const char* fallback = "Controller";
        if (style & HidNpadStyleTag_NpadFullKey) {
            key = "emulator_pad_pro";
            fallback = "Pro Controller";
        } else if (style & HidNpadStyleTag_NpadHandheld) {
            key = "emulator_pad_handheld";
            fallback = "Handheld";
        } else if (style & HidNpadStyleTag_NpadJoyDual) {
            key = "emulator_pad_joycon_pair";
            fallback = "Joy-Con pair";
        } else if (style & HidNpadStyleTag_NpadJoyLeft) {
            key = "emulator_pad_joycon_left";
            fallback = "Left Joy-Con";
        } else if (style & HidNpadStyleTag_NpadJoyRight) {
            key = "emulator_pad_joycon_right";
            fallback = "Right Joy-Con";
        } else if (style & HidNpadStyleTag_NpadGc) {
            key = "emulator_pad_gamecube";
            fallback = "GameCube controller";
        }
        return Tr(key, fallback);
    };
    std::vector<std::string> names;
    // player 1 is the first controller or the handheld console; without the
    // multitap port 2 is the second controller, with it every controller is a player
    const int players = Multitap() ? kMultitapPlayers : 2;
    for (int p = 0; p < players; p++) {
        u32 style = hidGetNpadStyleSet(static_cast<HidNpadIdType>(HidNpadIdType_No1 + p));
        if (p == 0 && !style)
            style = hidGetNpadStyleSet(HidNpadIdType_Handheld);
        names.push_back(style ? name(style) : std::string());
    }
    return names;
}

bool ShowControllerOrder() {
    HidLaControllerSupportArg arg;
    hidLaCreateControllerSupportArg(&arg);
    arg.hdr.player_count_min = 0;
    // the Saturn's two ports, or every controller through the multitap
    arg.hdr.player_count_max = Multitap() ? kMultitapPlayers : 2;
    HidLaControllerSupportResultInfo info{};
    return R_SUCCEEDED(hidLaShowControllerSupport(&info, &arg));
}

// ---------------------------------------------------------------------------

struct NavRepeat {
    u64 button = 0;
    u64 at = 0;

    u64 Apply(u64 held, u64 pressed) {
        constexpr u64 kDirections = HidNpadButton_AnyUp | HidNpadButton_AnyDown |
                                    HidNpadButton_AnyLeft | HidNpadButton_AnyRight;
        const u64 now = NowMs();
        if (pressed & kDirections) {
            button = pressed & kDirections;
            at = now + kRepeatDelayMs;
            return pressed;
        }
        if (!button || !(held & button)) {
            button = 0;
            return pressed;
        }
        if (now >= at) {
            at = now + kRepeatRateMs;
            return pressed | button;
        }
        return pressed;
    }
};

struct State {
    Host host;
    bool library = false;
    bool open = false;
    bool exit_requested = false;
    bool restart_requested = false;
    bool resume_offered = false;
    bool notice_open = false;
    NavRepeat repeat;
    std::array<unsigned long long, kSlotCount> pictures{};
    std::vector<Cheat> cheats;
    std::vector<Disc> discs;
    std::string current_disc;
};
State s;

std::string StatePath(int slot) {
    return std::string(tico_states_dir()) + tico_game_stem() +
           (slot == kAutoSlot ? std::string(".auto") : ".state" + std::to_string(slot));
}

// <state>.png beside the state, which tico shows too
std::string PreviewPath(int slot) {
    return StatePath(slot) + ".png";
}

// What earlier builds wrote instead, raw: still read until the slot is saved again
std::string LegacyPreviewPath(int slot) {
    return StatePath(slot) + ".thumb";
}

// The paused frame, shrunk to fit kPreviewMaxWidth x kPreviewMaxHeight (box
// filtered), beside the state.
void WritePreview(int slot) {
    std::vector<uint8_t> rgba;
    int width = 0, height = 0;
    if (!s.host.paused_frame || !s.host.paused_frame(rgba, width, height) || width <= 0 ||
        height <= 0)
        return;
    const float fit = std::min({1.0f, static_cast<float>(kPreviewMaxWidth) / width,
                                static_cast<float>(kPreviewMaxHeight) / height});
    const int out_w = std::max(1, static_cast<int>(width * fit));
    const int out_h = std::max(1, static_cast<int>(height * fit));
    std::vector<uint8_t> out(static_cast<std::size_t>(out_w) * out_h * 4);
    for (int y = 0; y < out_h; y++) {
        const int y0 = y * height / out_h, y1 = std::max(y0 + 1, (y + 1) * height / out_h);
        for (int x = 0; x < out_w; x++) {
            const int x0 = x * width / out_w, x1 = std::max(x0 + 1, (x + 1) * width / out_w);
            unsigned sum[3] = {0, 0, 0}, n = 0;
            for (int sy = y0; sy < y1; sy++) {
                const uint8_t* px = rgba.data() + (static_cast<std::size_t>(sy) * width + x0) * 4;
                for (int sx = x0; sx < x1; sx++, px += 4) {
                    sum[0] += px[0];
                    sum[1] += px[1];
                    sum[2] += px[2];
                    n++;
                }
            }
            uint8_t* dst = out.data() + (static_cast<std::size_t>(y) * out_w + x) * 4;
            dst[0] = sum[0] / n;
            dst[1] = sum[1] / n;
            dst[2] = sum[2] / n;
            dst[3] = 255;
        }
    }
    if (stbi_write_png(PreviewPath(slot).c_str(), out_w, out_h, 4, out.data(), out_w * 4))
        std::remove(LegacyPreviewPath(slot).c_str());
}

// The picture of an earlier build's state, if it has one.
bool ReadLegacyPreview(int slot, std::vector<uint8_t>& rgba, int& width, int& height) {
    FILE* fp = std::fopen(LegacyPreviewPath(slot).c_str(), "rb");
    if (!fp)
        return false;
    uint32_t header[3] = {};
    bool ok = std::fread(header, sizeof(header), 1, fp) == 1 && header[0] == kPreviewMagic &&
              header[1] > 0 && header[1] <= 4096 && header[2] > 0 && header[2] <= 4096;
    if (ok) {
        width = static_cast<int>(header[1]);
        height = static_cast<int>(header[2]);
        rgba.resize(static_cast<std::size_t>(width) * height * 4);
        ok = std::fread(rgba.data(), 1, rgba.size(), fp) == rgba.size();
    }
    std::fclose(fp);
    return ok;
}

OverlayUI::SlotPreview Preview(int slot) {
    OverlayUI::SlotPreview preview;
    if (slot < 1 || slot > kSlotCount)
        return preview;
    unsigned long long& picture = s.pictures[static_cast<std::size_t>(slot - 1)];
    ImGuiOverlay::DestroyTexture(picture); // the slot may have been saved again
    picture = 0;
    struct stat status;
    if (stat(StatePath(slot).c_str(), &status) != 0)
        return preview;
    char when[32];
    std::strftime(when, sizeof(when), "%Y-%m-%d %H:%M", std::localtime(&status.st_mtime));
    preview.saved_at = when;
    std::vector<uint8_t> rgba;
    int width = 0, height = 0, channels = 0;
    if (unsigned char* png = stbi_load(PreviewPath(slot).c_str(), &width, &height, &channels, 4)) {
        rgba.assign(png, png + static_cast<std::size_t>(width) * height * 4);
        stbi_image_free(png);
    } else if (!ReadLegacyPreview(slot, rgba, width, height)) {
        return preview;
    }
    picture = ImGuiOverlay::CreateTexture(rgba.data(), width, height);
    preview.texture = picture;
    preview.aspect = static_cast<float>(width) / height;
    return preview;
}

// The disc a state was made with, beside it: a state goes by the name of the
// disc the game booted with, so after Change Disc it holds another disc's game.
std::string DiscPath(int slot) {
    return StatePath(slot) + ".disc";
}

void WriteStateDisc(int slot) {
    // a disc on a USB drive by its drive id: the drive may mount elsewhere next time
    const std::string disc = UsbStorage::IsMountPath(s.current_disc)
                                 ? UsbStorage::ToToken(s.current_disc)
                                 : s.current_disc;
    if (FILE* fp = std::fopen(DiscPath(slot).c_str(), "wb")) {
        std::fputs(disc.c_str(), fp);
        std::fclose(fp);
    }
}

// Puts the disc a state was made with in the drive before the state loads,
// so the game finds the disc it was playing.
void InsertStateDisc(int slot) {
    std::string disc;
    if (FILE* fp = std::fopen(DiscPath(slot).c_str(), "rb")) {
        char line[1024] = {0};
        if (std::fgets(line, sizeof(line), fp))
            disc = Trim(line);
        std::fclose(fp);
    }
    if (UsbStorage::IsToken(disc))
        disc = UsbStorage::Resolve(disc);
    if (disc.empty() || disc == s.current_disc || !IsFile(disc))
        return;
    Cs2ForceOpenTray();
    if (Cs2ForceCloseTray(CDCORE_ISO, disc.c_str()) == 0) {
        LOG_INFO("STATE", "slot %d was made with %s: inserted", slot, disc.c_str());
        s.current_disc = disc;
    }
}

bool SaveState(int slot) {
    tico_make_path(tico_states_dir());
    // the state it replaces is kept, in case this one is a mistake
    TicoSafeFile::BackupCopy(StatePath(slot), kStateBackups);
    const bool saved = YabSaveState(StatePath(slot).c_str()) == 0;
    if (saved) {
        WritePreview(slot);
        WriteStateDisc(slot);
    }
    LOG_INFO("STATE", "save slot %d: %s", slot, saved ? "ok" : "failed");
    return saved;
}

bool LoadState(int slot) {
    if (!IsFile(StatePath(slot)))
        return false;
    InsertStateDisc(slot);
    const bool loaded = YabLoadState(StatePath(slot).c_str()) == 0;
    // stale samples from before the load play as noise
    SNDSDLClearBuffer();
    LOG_INFO("STATE", "load slot %d: %s", slot, loaded ? "ok" : "failed");
    return loaded;
}

// ---------------------------------------------------------------------------

std::vector<OverlayUI::CheatMenuEntry> CheatEntries() {
    std::vector<OverlayUI::CheatMenuEntry> entries;
    OverlayUI::CheatMenuEntry add;
    add.name = Tr("yabasanshiro_add_cheat", "Add cheat");
    add.is_add_row = true;
    add.source_index = -1;
    entries.push_back(add);
    for (std::size_t i = 0; i < s.cheats.size(); i++) {
        OverlayUI::CheatMenuEntry entry;
        entry.name = s.cheats[i].name;
        entry.enabled = s.cheats[i].enabled;
        entry.source_index = static_cast<int>(i);
        entries.push_back(entry);
    }
    return entries;
}

bool ToggleCheat(int index) {
    if (index < 0 || index >= static_cast<int>(s.cheats.size()))
        return false;
    Cheat& cheat = s.cheats[static_cast<std::size_t>(index)];
    cheat.enabled = !cheat.enabled;
    for (const std::string& code : cheat.codes) {
        if (cheat.enabled)
            CheatAddARCode(code.c_str());
        else
            CheatRemoveARCode(code.c_str());
    }
    return true;
}

void AddCheat() {
    std::string name, codes;
    if (!PromptKeyboard(Tr("yabasanshiro_new_cheat", "New cheat").c_str(),
                        Tr("yabasanshiro_enter_name", "Name").c_str(), "", 95, false, name) ||
        name.empty())
        return;
    if (!PromptKeyboard(Tr("yabasanshiro_action_replay_code", "Action Replay code").c_str(),
                        "XXXXXXXX YYYY", "", 4095, true, codes))
        return;
    Cheat cheat;
    cheat.name = name;
    cheat.codes = ParseCodes(codes);
    if (cheat.codes.empty()) {
        OverlayUI::ShowToast(Tr("yabasanshiro_invalid_code", "That is not an Action Replay code"));
        return;
    }
    s.cheats.push_back(std::move(cheat));
    ToggleCheat(static_cast<int>(s.cheats.size()) - 1);
    OverlayUI::RefreshCheatList();
    OverlayUI::ShowToast(Tr("yabasanshiro_cheat_added", "Cheat added"));
}

std::vector<OverlayUI::DiscMenuEntry> DiscEntries() {
    std::vector<OverlayUI::DiscMenuEntry> entries;
    for (const Disc& disc : s.discs)
        entries.push_back({disc.name, disc.path == s.current_disc});
    return entries;
}

void SwapDisc(int index) {
    if (index < 0 || index >= static_cast<int>(s.discs.size()))
        return;
    const Disc& disc = s.discs[static_cast<std::size_t>(index)];
    if (disc.path == s.current_disc)
        return;
    Cs2ForceOpenTray();
    if (Cs2ForceCloseTray(CDCORE_ISO, disc.path.c_str()) != 0) {
        OverlayUI::ShowToast(Tr("yabasanshiro_disc_failed", "Could not insert the disc"));
        return;
    }
    s.current_disc = disc.path;
    OverlayUI::ShowToast(disc.name);
}

void EditTextOption() {
    const TicoConfig::OptionDef* option = OverlayUI::ConsumeTextEditOption();
    if (!option)
        return;
    std::string value;
    const std::size_t length = option->max_length > 0 ? option->max_length : 64;
    const std::string header =
        Tr(option->label_key ? option->label_key : "", option->fallback ? option->fallback : "");
    if (!PromptKeyboard(header.c_str(), nullptr, TicoConfig::GetOptionValue(*option), length,
                        false, value))
        return;
    TicoConfig::SetOptionValue(*option, value);
    OverlayUI::NotifyOptionEdited(*option);
}

void FeedInput(u64 held, u64 pressed) {
    HidTouchScreenState touch{};
    if (hidGetTouchScreenStates(&touch, 1)) {
        ImGuiOverlay::FeedTouch({
            .down = touch.count > 0,
            .x = touch.count > 0 ? static_cast<float>(touch.touches[0].x) : 0.0f,
            .y = touch.count > 0 ? static_cast<float>(touch.touches[0].y) : 0.0f,
        });
    }
    pressed = s.repeat.Apply(held, pressed);
    ImGuiOverlay::FeedNav({
        .up = (pressed & HidNpadButton_AnyUp) != 0,
        .down = (pressed & HidNpadButton_AnyDown) != 0,
        .left = (pressed & HidNpadButton_AnyLeft) != 0,
        .right = (pressed & HidNpadButton_AnyRight) != 0,
        .accept = (pressed & HidNpadButton_A) != 0,
        .cancel = (pressed & HidNpadButton_B) != 0,
    });
}

void RunAction(OverlayUI::Action action) {
    using OverlayUI::Action;
    switch (action) {
    case Action::None:
        return;
    case Action::Resume:
        Close();
        return;
    case Action::Exit:
        s.exit_requested = true;
        Close();
        return;
    case Action::Reset:
        YabauseResetButton();
        Close();
        return;
    case Action::Restart:
        s.restart_requested = true;
        s.exit_requested = true;
        Close();
        return;
    case Action::EditText:
        EditTextOption();
        return;
    case Action::AddCheat:
        AddCheat();
        return;
    case Action::SwapDisc:
        SwapDisc(OverlayUI::ConsumeDiscIndex());
        Close();
        return;
    case Action::ControllerOrder:
        // the players may be in another order now: the frontend notices
        if (!ShowControllerOrder())
            OverlayUI::ShowToast(Tr("emulator_controllers_failed",
                                    "Could not open the controller screen"),
                                 OverlayUI::ToastCorner::TopRight);
        return;
    case Action::NoticeChoice: {
        const int choice = OverlayUI::ConsumeNoticeChoice();
        s.notice_open = false;
        if (choice == 1)
            s.exit_requested = true; // Exit Game
        Close();
        return;
    }
    default:
        break;
    }
    if (OverlayUI::IsSaveStateAction(action)) {
        const int slot = OverlayUI::GetStateSlotForAction(action);
        OverlayUI::ShowToast(SaveState(slot)
                                 ? TrFormat("yabasanshiro_state_saved", "State saved (slot %d)", slot)
                                 : TrFormat("yabasanshiro_save_failed", "Could not save slot %d", slot));
        Close();
    } else if (OverlayUI::IsLoadStateAction(action)) {
        const int slot = OverlayUI::GetStateSlotForAction(action);
        if (YabaRA::Hardcore()) {
            OverlayUI::ShowToast(Tr("yabasanshiro_hardcore_no_load", "Not in hardcore mode"));
        } else if (LoadState(slot)) {
            OverlayUI::ShowToast(slot == kAutoSlot
                                     ? Tr("emulator_auto_loaded", "Auto save loaded")
                                     : TrFormat("yabasanshiro_state_loaded", "State loaded (slot %d)", slot));
        } else {
            OverlayUI::ShowToast(TrFormat("yabasanshiro_load_failed", "Could not load slot %d", slot));
        }
        Close();
    }
}

} // namespace

void Init(const Host& host, bool library_mode) {
    s = {};
    s.host = host;
    s.library = library_mode;
    s.current_disc = tico_disc_path();

    OverlayUI::SetGameTitle(tico_display_title());
    OverlayUI::SetLibraryMode(library_mode);
    if (library_mode) {
        TicoLibrary::Register([](const std::string& rom) {
            if (tico_queue_library_game(rom.c_str()))
                s.exit_requested = true;
        });
        return;
    }
    TicoConfig::SetGame(tico_rom_path());
    OverlayUI::SetHardcoreMode(YabaRA::Hardcore());
    OverlayUI::SetSlotOccupiedCallback([](int slot) { return IsFile(StatePath(slot)); });
    OverlayUI::SetSlotPreviewCallback(Preview);
    OverlayUI::SetCheatCallbacks(CheatEntries, ToggleCheat);
    OverlayUI::PlayerCallbacks players;
    players.ports = [] { return ControllerNames(); };
    players.note = [] {
        if (Multitap())
            return Tr("yabasanshiro_players_note_multitap",
                      "Multitap: players 1 to 6 on port 1, 7 and 8 on port 2.");
        return Tr("yabasanshiro_players_note",
                  "The Saturn has two controller ports: the first two controllers.");
    };
    OverlayUI::SetPlayerCallbacks(std::move(players));
    s.discs = FindDiscs(s.current_disc);
    if (s.discs.size() > 1)
        OverlayUI::SetDiscCallback(DiscEntries);
}

void Shutdown() {
    for (unsigned long long& picture : s.pictures) {
        ImGuiOverlay::DestroyTexture(picture);
        picture = 0;
    }
    if (s.library)
        TicoLibrary::Unregister();
    OverlayUI::SetSlotOccupiedCallback({});
    OverlayUI::SetSlotPreviewCallback({});
    OverlayUI::SetCheatCallbacks({}, {});
    OverlayUI::SetDiscCallback({});
    OverlayUI::SetPlayerCallbacks({});
}

void Open() {
    if (s.open)
        return;
    // opening the menu pauses the game, which hardcore only allows so often
    int wait = 0;
    if (!s.library && !s.notice_open && !YabaRA::CanPause(wait)) {
        OverlayUI::ShowToast(TrFormat("emulator_hardcore_pause_wait",
                                      "You can pause again in %d s", wait));
        return;
    }
    s.open = true;
    s.repeat = {};
    OverlayUI::SetHardcoreMode(YabaRA::Hardcore());
    ImGuiOverlay::SetVisible(true);
}

void Close() {
    // the game list has nothing to go back to
    if (!s.open || (s.library && !s.exit_requested))
        return;
    s.open = false;
    ImGuiOverlay::SetVisible(false);
}

bool IsOpen() {
    return s.open;
}

void Update(u64 held, u64 pressed) {
    if (!s.open) {
        if ((held & kToggleCombo) == kToggleCombo && (pressed & kToggleCombo))
            Open();
        return;
    }
    // the combo that opened the menu also closes it
    if (!s.library && !s.notice_open && (held & kToggleCombo) == kToggleCombo &&
        (pressed & kToggleCombo)) {
        Close();
        return;
    }
    FeedInput(held, pressed);
    RunAction(ImGuiOverlay::ConsumeAction());
    if (OverlayUI::ConsumeSettingsChanged() && s.host.apply_live_settings)
        s.host.apply_live_settings();
}

void OfferResume() {
    if (s.resume_offered || s.library)
        return;
    s.resume_offered = true;
    const bool restarted = tico_was_restarted();
    // tico's General > Quick Menu Tip: shown once the game runs smoothly
    if (!restarted)
        OverlayUI::ShowQuickMenuTip();
    if (restarted || !IsFile(StatePath(kAutoSlot)) || YabaRA::Hardcore())
        return;
    const std::string mode = TicoConfig::ResumeOnLaunch();
    if (mode == "never")
        return;
    if (mode == "always") {
        if (LoadState(kAutoSlot))
            OverlayUI::ShowToast(Tr("emulator_auto_loaded", "Auto save loaded"));
        return;
    }
    Open();
    // the prompt loads the auto save's picture as it opens: a texture made
    // while the VDP thread holds the renderer comes out empty
    if (s.host.pause)
        s.host.pause();
    OverlayUI::ShowResumePrompt();
}

void AutoSave() {
    if (!s.library && tico_game_stem()[0])
        SaveState(kAutoSlot);
}

void Notice(const std::string& message) {
    s.notice_open = true;
    Open();
    OverlayUI::ShowNotice(message, {Tr("yabasanshiro_continue", "Continue"),
                                    Tr("emulator_exit_game", "Exit Game")});
}

bool TakeExitRequest() {
    const bool requested = s.exit_requested;
    s.exit_requested = false;
    return requested;
}

bool TakeRestartRequest() {
    const bool requested = s.restart_requested;
    s.restart_requested = false;
    return requested;
}

void LoadCheats() {
    s.cheats = ReadTicoCheats(tico_game_stem());
    LOG_INFO("CHEATS", "%zu cheats for %s", s.cheats.size(), tico_game_stem());
}

void SetHud(float fps, int width, int height) {
    OverlayUI::SetHudStats({.fps = fps, .rendered_width = width, .rendered_height = height});
}

} // namespace YabaMenu
