// tico frontend entry for YabaSanshiro: the launch arguments, the content
// folders and the way back to tico.

#include "tico_entry.h"

#include <switch.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>

#include "TicoSession.h"
#include "UsbStorage.h"
#include "overlay/tico_config.h"

namespace {

// Restart relaunches this NRO with this argument added, so the game starts
// over instead of offering to continue from the auto save.
constexpr const char* kRestartArgument = "--tico-restart";
// A game chosen from the game list is launched with this argument, so Exit
// Game goes back to the list instead of to tico.
constexpr const char* kLibraryArgument = "--from-library";

std::string s_disc;
std::string s_rom;
std::string s_title;
std::string s_stem;
std::string s_system_dir;
std::string s_legacy_system_dir;
std::string s_saves_dir;
std::string s_states_dir;
std::string s_bios;
bool s_restarted = false;
bool s_from_library = false;
bool s_library_mode = false;
std::string s_self;
// the launch arguments, quoted, for Restart
std::string s_launch_arguments;

bool IsFile(const std::string& path) {
    struct stat status;
    return stat(path.c_str(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size > 0;
}

std::string WithSlash(std::string path) {
    if (!path.empty() && path.back() != '/')
        path += '/';
    return path;
}

// A content folder chosen in tico's module Paths tab, or tico's default.
std::string ContentRoot(const char* key, const char* default_root) {
    const std::string root = SwitchFrontend::TicoConfig::GetConfigValue(key, "");
    return WithSlash(root.empty() ? default_root : root);
}

bool IsFlag(const char* argument) {
    return !argument || !argument[0] || !std::strcmp(argument, "ticoSetup") ||
           !std::strcmp(argument, kRestartArgument) || !std::strcmp(argument, kLibraryArgument);
}

// tico names a game on a USB drive usb://<volume-id>/<path>: the drive with
// that id, wherever it is mounted for this process.
std::string ResolveUsb(const std::string& rom) {
    if (!UsbStorage::IsToken(rom))
        return rom;
    const std::string mounted = UsbStorage::Resolve(rom);
    return mounted.empty() ? rom : mounted;
}

std::string StemOf(const std::string& path) {
    std::string name = path.substr(path.find_last_of('/') + 1);
    const std::size_t dot = name.find_last_of('.');
    return dot == std::string::npos ? name : name.substr(0, dot);
}

void FindBios() {
    const std::string candidates[] = {
        s_system_dir + "saturn_bios.bin",
        s_system_dir + "sega_101.bin",
        s_system_dir + "mpr-17933.bin",
        s_legacy_system_dir + "saturn_bios.bin",
        s_legacy_system_dir + "sega_101.bin",
        s_legacy_system_dir + "mpr-17933.bin",
        "sdmc:/tiicu/system/saturn/saturn_bios.bin",
        "./yabasanshiro/saturn_bios.bin",
    };
    for (const std::string& candidate : candidates) {
        if (IsFile(candidate)) {
            s_bios = candidate;
            tico_log("BIOS: %s\n", s_bios.c_str());
            return;
        }
    }
    tico_log("no BIOS found: the core emulates it\n");
}

void RememberLaunch(int argc, char** argv) {
    if (argc > 0 && argv[0] && argv[0][0])
        s_self = argv[0];
    for (int i = 0; i < argc && argv[i]; i++) {
        if (!std::strcmp(argv[i], kRestartArgument)) {
            s_restarted = true;
            continue;
        }
        if (!std::strcmp(argv[i], kLibraryArgument))
            s_from_library = true;
        if (!s_launch_arguments.empty())
            s_launch_arguments += ' ';
        s_launch_arguments += '"' + std::string(argv[i]) + '"';
    }
}

// This NRO with the given arguments (each quoted) for when this process exits.
bool QueueSelf(const std::string& arguments) {
    if (!envHasNextLoad() || s_self.empty() || !IsFile(s_self))
        return false;
    static std::string line;
    line = '"' + s_self + '"' + (arguments.empty() ? "" : " " + arguments);
    return R_SUCCEEDED(envSetNextLoad(s_self.c_str(), line.c_str()));
}

} // namespace

extern "C" {

void tico_make_path(const char* path) {
    std::string partial = path;
    // skip a device prefix such as sdmc:/
    std::size_t start = partial.find(":/");
    start = start == std::string::npos ? 1 : start + 2;
    for (std::size_t i = start; i < partial.size(); i++) {
        if (partial[i] != '/')
            continue;
        mkdir(partial.substr(0, i).c_str(), 0777);
    }
    mkdir(partial.c_str(), 0777);
}

void tico_prepare(int argc, char** argv) {
    RememberLaunch(argc, argv);

    // the core's own folder, as tico's other cores (module.json's system_dir)
    s_system_dir = ContentRoot("tico_system_path", "sdmc:/tico/system/") + "yabasanshiro/";
    s_legacy_system_dir = ContentRoot("tico_system_path", "sdmc:/tico/system/") + TICO_CORE_SLUG "/";
    s_saves_dir = tico::UserContentRoot(ContentRoot("tico_saves_path", "sdmc:/tico/saves/"), true) +
                  TICO_CORE_SLUG "/";
    s_states_dir =
        tico::UserContentRoot(ContentRoot("tico_states_path", "sdmc:/tico/states/"), false) +
        TICO_CORE_SLUG "/";
    tico_make_path(s_system_dir.c_str());
    tico_make_path(s_saves_dir.c_str());
    tico_make_path(s_states_dir.c_str());
    FindBios();

    // the disc is the first argument that is not a flag; the title follows it
    int disc_index = -1;
    for (int i = 1; i < argc; i++) {
        if (!IsFlag(argv[i])) {
            disc_index = i;
            break;
        }
    }
    if (disc_index < 0) {
        // started on its own: the game list picks one and launches it
        s_library_mode = true;
        s_title = "YabaSanshiro";
        return;
    }
    s_rom = argv[disc_index];
    s_disc = ResolveUsb(s_rom);
    s_stem = StemOf(s_rom);
    for (int i = disc_index + 1; i < argc; i++) {
        if (!IsFlag(argv[i])) {
            s_title = argv[i];
            break;
        }
    }
    if (s_title.empty())
        s_title = s_stem;
    tico_log("disc: %s (%s)\n", s_disc.c_str(), s_title.c_str());
}

const char* tico_disc_path(void) { return s_disc.c_str(); }
const char* tico_rom_path(void) { return s_rom.c_str(); }
const char* tico_display_title(void) { return s_title.c_str(); }
const char* tico_game_stem(void) { return s_stem.c_str(); }
const char* tico_system_dir(void) { return s_system_dir.c_str(); }
const char* tico_legacy_system_dir(void) { return s_legacy_system_dir.c_str(); }
const char* tico_saves_dir(void) { return s_saves_dir.c_str(); }
const char* tico_states_dir(void) { return s_states_dir.c_str(); }
const char* tico_bios_path(void) { return s_bios.empty() ? nullptr : s_bios.c_str(); }
bool tico_was_restarted(void) { return s_restarted; }
bool tico_library_mode(void) { return s_library_mode; }

bool tico_queue_library_game(const char* rom) {
    return QueueSelf('"' + std::string(rom) + "\" \"\" \"" + kLibraryArgument + '"');
}

bool tico_queue_restart(void) {
    if (!envHasNextLoad() || s_self.empty() || !IsFile(s_self))
        return false;
    static std::string arguments;
    arguments = s_launch_arguments + " \"" + kRestartArgument + '"';
    return R_SUCCEEDED(envSetNextLoad(s_self.c_str(), arguments.c_str()));
}

bool tico_queue_return(void) {
    // a game from the game list goes back to it
    if (s_from_library)
        return QueueSelf("");
    if (!envHasNextLoad() || !IsFile(TICO_LAUNCHER_PATH))
        return false;
    return R_SUCCEEDED(envSetNextLoad(TICO_LAUNCHER_PATH, TICO_LAUNCHER_PATH " --resume"));
}

void tico_log(const char* format, ...) {
    static FILE* file;
    if (!file) {
        tico_make_path("sdmc:/tico/logs");
        file = std::fopen(TICO_LOG_PATH, "w");
        if (!file)
            return;
    }
    va_list arguments;
    va_start(arguments, format);
    std::vfprintf(file, format, arguments);
    va_end(arguments);
    std::fflush(file);
}

} // extern "C"
