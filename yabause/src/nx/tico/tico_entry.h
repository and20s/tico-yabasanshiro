/* tico frontend entry for YabaSanshiro.
 *
 * tico chainloads tico-yabasanshiro.nro with the disc image in the launch
 * arguments and the game's display title after it; on exit the NRO chainloads
 * back to tico with --resume. Started without a disc, it shows a list of the
 * games in tico's ROM folders and launches the chosen one. */
#ifndef YABA_TICO_ENTRY_H
#define YABA_TICO_ENTRY_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TICO_LAUNCHER_PATH "sdmc:/switch/tico/tico.nro"
#define TICO_CORE_ID "yabasanshiro"
#define TICO_CORE_SLUG "saturn"

/* Creates a directory and any missing parents. */
void tico_make_path(const char *path);

/* Reads the launch arguments: the disc, its title, Restart and the game list.
 * Call once the tico config is loaded, since it names the content folders. */
void tico_prepare(int argc, char **argv);

/* The disc to boot (a usb:// path resolved to the drive), empty in library mode. */
const char *tico_disc_path(void);
/* The game as tico named it (usb://... included), which names its per-game
 * settings, saves and states. */
const char *tico_rom_path(void);
const char *tico_display_title(void);
/* The file name tico_rom_path has without its folder and extension, which
 * names the game's backup RAM and states. */
const char *tico_game_stem(void);

/* The content folders, each with a trailing '/': the module's system folder
 * (<root>/saturn/), and this user's saves and states (<root>/saturn/). */
const char *tico_system_dir(void);
/* sdmc:/tico/system/saturn/, where earlier builds kept the BIOS and the
 * cartridge dumps: still looked in, so an upgrade boots as before. */
const char* tico_legacy_system_dir(void);
const char *tico_saves_dir(void);
const char *tico_states_dir(void);

/* The Saturn BIOS found in the system folder (or the old locations), or NULL:
 * the core then emulates the BIOS. */
const char *tico_bios_path(void);

/* True when this launch is a Restart (tico_queue_restart): the game starts
 * over instead of offering to continue from the auto save. */
bool tico_was_restarted(void);

/* True when started without a game: the frontend shows the game list. */
bool tico_library_mode(void);

/* Queues this NRO with the same game for when this process exits. */
bool tico_queue_restart(void);

/* Queues this NRO with a game chosen from the game list; Exit Game in it
 * comes back to the list. */
bool tico_queue_library_game(const char *rom);

/* Queues tico to be loaded with --resume when this process exits (or the game
 * list, for a game started from it). */
bool tico_queue_return(void);

/* Appends to TICO_LOG_PATH. */
void tico_log(const char *format, ...) __attribute__((format(printf, 1, 2)));
#define TICO_LOG_PATH "sdmc:/tico/logs/yabasanshiro.log"

#ifdef __cplusplus
}
#endif

#endif
