/*  Standalone backup RAM access.

    Opens the internal backup RAM file and (optionally) a cartridge backup RAM
    file without starting emulation, so the platform UI can list, delete and
    copy saves while no game is running.

    The session shares the BupRam / CartridgeArea / mapped memory globals with
    the emulator, so it MUST be closed before YabauseInit is called.
*/

#ifndef BUPSTANDALONE_H
#define BUPSTANDALONE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Opens a standalone backup RAM session.
   buppath  : path of the internal backup RAM file (required)
   cartpath : path of the cartridge backup RAM file, or NULL
   carttype : one of the CART_* constants; use CART_NONE when cartpath is NULL
   Returns 0 on success, -1 on failure. Calling it twice without closing
   returns -1. */
int YabBupStandaloneOpen(const char *buppath, const char *cartpath, int carttype);

/* Flushes and releases the session. Safe to call when not open. */
void YabBupStandaloneClose(void);

/* Non-zero while a session is open. */
int YabBupStandaloneIsOpen(void);

/* Packs a calendar date into the format saveinfo_struct.date uses.
   year is the full year (e.g. 1998), month 1-12, day 1-31.
   Returns the packed value, or 0 when the date cannot be represented. */
unsigned int YabBupEncodeDate(int year, int month, int day, int hour, int minute);

/* Unpacks the format saveinfo_struct.date uses. Mirrors the decoding in
   BupGetSaveList. Any out parameter may be NULL. */
void YabBupDecodeDate(unsigned int date, int *year, int *month, int *day,
                      int *hour, int *minute);

#ifdef __cplusplus
}
#endif

#endif
