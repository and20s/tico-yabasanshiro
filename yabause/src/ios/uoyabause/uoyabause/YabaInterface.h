//
//  ChdWrapper.h
//  YabaSnashiro
//
//  Created by Shinya Miyamoto on 2024/07/14.
//  Copyright © 2024 devMiyax. All rights reserved.
//
#import <Foundation/Foundation.h>
#import <MetalANGLE/MGLKViewController.h>
#include <stddef.h>  // for size_t
#include <stdint.h>  // for uint8_t, uint32_t

extern BOOL _bios;
extern int _cart;
extern BOOL _fps;
extern BOOL _frame_skip;
extern BOOL _aspect_rate;
extern int _filter;
extern int _sound_engine;
extern int _rendering_resolution;
extern BOOL _rotate_screen;
extern float _controller_scale;
extern const char * currentGamePath;

extern MGLContext *g_context;
extern MGLContext *g_share_context;
extern MGLLayer *glLayer;
extern NSObject* _objectForLock;


extern const int MSG_SAVE_STATE;
extern const int MSG_LOAD_STATE;
extern const int MSG_RESET;
extern const int MSG_OPEN_TRAY;
extern const int MSG_CLOSE_TRAY;

//    MSG_RESUME,
//    MSG_OPEN_TRAY,
//    MSG_CLOSE_TRAY,
//    MSG_RESET,

static const unsigned int PERANALOG_AXIS_X = 18; // left to right
static const unsigned int PERANALOG_AXIS_Y = 19; // up to down
static const unsigned int PERANALOG_AXIS_RTRIGGER = 20; // right trigger
static const unsigned int PERANALOG_AXIS_LTRIGGER = 21; // left trigger

void PerKeyDown(unsigned int key);
void PerKeyUp(unsigned int key);
int SetAnalogMode(int mode);
void PerAxisValue(unsigned int, unsigned char val);
int start_emulation( int originx, int originy, int width, int height );
void resize_screen( int x, int y, int width, int height );
int emulation_step( int command );
int enterBackGround();
int MuteSound();
int UnMuteSound();


char * getGameinfoFromChd( const char * path );


NSString* YSGetBackupDevicelist();
NSString* YSGetBackupFilelist( int deviceid );
int YSDeleteBackupFile( int index );
NSString* YSGetBackupFile( int index );
int YSPutFile( NSString* jsonstr  );
int YSCopy( int target, int file  );

#ifdef __cplusplus
extern "C" {
#endif

/* Standalone backup RAM access (no emulation running).
 * Open before calling any YSBupStandalone* function, close when done. */
int  YSBupStandaloneOpen(const char *buppath, const char *cartpath, int carttype);
void YSBupStandaloneClose(void);

/* One save entry. Mirrors saveinfo_struct plus what the UI needs. */
typedef struct {
    char filename[12];
    char comment[11];
    unsigned char language;
    unsigned char year;
    unsigned char month;
    unsigned char day;
    unsigned char hour;
    unsigned char minute;
    unsigned char week;
    unsigned int  datasize;
    unsigned short blocksize;
} YSBupSave;

/* Fills buffer with up to maxCount saves of the given device.
 * Returns the number written, or -1 on failure. */
int YSBupStandaloneList(int deviceId, YSBupSave *buffer, int maxCount);

/* Fills the out params with byte/block counts of the device.
 * Returns 0 on success. */
int YSBupStandaloneStatus(int deviceId, unsigned int *totalSize, unsigned int *freeSize,
                          unsigned int *totalBlock, unsigned int *freeBlock);

/* Deletes a save by name. Returns 0 on success. */
int YSBupStandaloneDelete(int deviceId, const char *savename);

/* Copies a save between two devices of the OPEN session.
 * Returns 0 on success, -2 when the destination has no room, -1 otherwise. */
int YSBupStandaloneCopy(int srcDeviceId, int dstDeviceId, const char *savename);

/* Test helper: writes a synthetic save into the open session.
 * Returns 0 on success. */
int YSBupStandaloneCreateForTest(int deviceId, const char *name, const char *comment,
                                 const void *data, int dataSize);

/* Exports the raw save bytes of a save in the open session.
 * On success *buffer holds malloc'd bytes the caller must free().
 * Returns 0 on success. */
int YSBupStandaloneExport(int deviceId, const char *savename,
                          void **buffer, int *size);

/* Imports raw save bytes into the open session.
 * saturnDate is the packed value from YSBupEncodeDate.
 * Returns 0 on success, -2 when the device has no room, -1 otherwise. */
int YSBupStandaloneImport(int deviceId, const char *name, const char *comment,
                          unsigned char language, unsigned int saturnDate,
                          const void *data, int dataSize);

/* Packs a calendar date the way saveinfo_struct.date expects.
 * Returns 0 when the date cannot be represented. */
unsigned int YSBupEncodeDate(int year, int month, int day, int hour, int minute);

#ifdef __cplusplus
}
#endif

void YSUpdateCheat(NSArray* stringArray);
NSString* YSGetCurrentGameCode();
// Implemented in Swift via @_cdecl. Xcode 26 emits this declaration in
// YabaSnashiro-Swift.h as SWIFT_EXTERN (extern "C") plus SWIFT_NOEXCEPT, so the
// C++ view here must match both the linkage and the exception specification;
// otherwise the two declarations conflict in .mm translation units.
#ifdef __cplusplus
extern "C" void YSOnBackupWrite(const char *fname, int deviceId, const void *before, const void *after, int size) noexcept;
#else
void YSOnBackupWrite(const char *fname, int deviceId, const void *before, const void *after, int size);
#endif


// RetroAchievements integration functions
#ifdef __cplusplus
extern "C" {
#endif

struct YabauseRA_AchievementList;

// Core initialization and shutdown
int YabauseRA_Initialize();
void YabauseRA_Shutdown();

// User authentication
int YabauseRA_InitializeUser(const char* username, const char* token);
void YabauseRA_Logout();
int YabauseRA_IsUserLoggedIn();
const char* YabauseRA_GetUsername();

// Hardcore mode management
void YabauseRA_SetHardcoreEnabled(int enabled);
int YabauseRA_GetHardcoreEnabled();
void YabauseRA_Reset();

// Game loading and identification
int YabauseRA_LoadGame(const char* hash);
int YabauseRA_LoadGameFromFile(const char* path);
const char* YabauseRA_GetGameHash();

// Rich presence system
void YabauseRA_UpdateRichPresence(const char* richPresence);
const char* YabauseRA_GetRichPresenceDisplayString();

// Achievement and leaderboard callbacks
void YabauseRA_OnAchievementTriggered(int achievementId);
void YabauseRA_TestAchievementUnlock(int achievementId);
void YabauseRA_OnLeaderboardSubmitted(int leaderboardId, int score);

// Memory interface for achievement evaluation
uint32_t YabauseRA_ReadMemory(uint32_t address, uint32_t size);

// Frame processing
void YabauseRA_DoFrame();
void YabauseRA_SetPaused(int paused);
int YabauseRA_GetPaused();

// Media change support for multi-disc games
int YabauseRA_BeginChangeMedia(const char* new_media_path);

// Game image URL
int YabauseRA_GetGameImageURL(char* buffer, size_t buffer_size);

// Progress serialization
size_t YabauseRA_GetProgressSize();
int YabauseRA_SerializeProgress(uint8_t* buffer, size_t buffer_size);
int YabauseRA_DeserializeProgress(const uint8_t* buffer, size_t buffer_size);

// Achievement badge image functions
const char* YabauseRA_GetAchievementBadgeURL(int achievementId, int state);
const char* YabauseRA_GetAchievementBadgeName(int achievementId);



// JSON-based achievement list (safer than struct-based approach)
char* YabauseRA_CreateAchievementListJSON(int category, int grouping);

// Challenge Indicator JSON creation (includes badge URL and achievement details)
char* YabauseRA_CreateChallengeIndicatorJSON(const void* achievement);

/* Generate the RetroAchievements MD5 hash for a game file without
 * loading it into the emulator. Writes a 32-char hash + NUL terminator.
 * Returns 1 on success, 0 on failure. bufferSize must be >= 33. */
int YabauseRA_GenerateGameHash(const char* path, char* buffer, int bufferSize);

/* Session token of the currently logged-in RA user, or NULL. */
const char* YabauseRA_GetUserApiToken(void);

#ifdef __cplusplus
}
#endif

// Swift bridge class declaration (forward declaration)
@class RetroAchievementsBridge;
