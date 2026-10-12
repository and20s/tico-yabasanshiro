//
//  YabaInterface.m
//  YabaSnashiro
//
//  Created by Shinya Miyamoto on 2024/07/20.
//  Copyright © 2024 devMiyax. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#include <MetalANGLE/GLES3/gl3.h>
#import <MetalANGLE/MGLKViewController.h>
#include <string>
#include <string.h>
#include "../../../BackupManager.h"
#include "../../../bios.h"
#include "../../../bupstandalone.h"
#include "../../../cheat.h"
#include "../../../cs2.h"
#include "../../../retroachievements/yabause_ra_integration_cwrapper.h"
#include "../../../retroachievements/yabause_ra_integration.h"
#include "../../../retroachievements/rcheevos/include/rc_hash.h"
#include "../../../retroachievements/rcheevos/include/rc_client.h"

// Use rcheevos integration if available, fallback to iOS implementation
// Set to 0 to use iOS fallback, 1 to use rcheevos C++ wrapper
#define USE_RCHEEVOS_INTEGRATION 0

extern "C" {

#define CART_NONE            0
#define CART_PAR             1
#define CART_BACKUPRAM4MBIT  2
#define CART_BACKUPRAM8MBIT  3
#define CART_BACKUPRAM16MBIT 4
#define CART_BACKUPRAM32MBIT 5
#define CART_DRAM8MBIT       6
#define CART_DRAM32MBIT      7
#define CART_NETLINK         8
#define CART_ROM16MBIT       9


MGLContext *g_context = nil;
MGLContext *g_share_context = nil;


// Settings
BOOL _bios =YES;
int _cart = 0;
BOOL _fps = NO;
BOOL _frame_skip = NO;
BOOL _aspect_rate = NO;
int _filter = 0;
int _sound_engine = 0;
int _rendering_resolution = 0;
BOOL _rotate_screen = NO;
float _controller_scale = 1.0;
const char * currentGamePath = NULL;

extern "C" const int MSG_SAVE_STATE = 1;
extern "C" const int MSG_LOAD_STATE = 2;
extern "C" const int MSG_RESET = 3;
extern "C" const int MSG_OPEN_TRAY = 4;
extern "C" const int MSG_CLOSE_TRAY = 5;


GLuint _renderBuffer = 0;
NSObject* _objectForLock;
MGLLayer *glLayer = nil;


int swapAglBuffer (void)
{
    if( glLayer == nil ) return 0;
    
    @synchronized (_objectForLock){
        MGLContext* context = [MGLContext currentContext];
        if (![context present:glLayer]) {
        }
    }
    return 0;
}

void RevokeOGLOnThisThread(void){
    [MGLContext setCurrentContext:g_share_context forLayer:glLayer];
}

void UseOGLOnThisThread(void){
    [MGLContext setCurrentContext:g_context forLayer:glLayer];
}

const char * GetBiosPath(void){
#if 1
    return NULL;
#else
    if( _bios == YES ){
        return NULL;
    }
    
    NSFileManager *filemgr;
    filemgr = [NSFileManager defaultManager];
    NSString * fileName = @"bios.bin";
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent: fileName];
    NSLog(@"full path name: %@", filePath);
    
    // check if file exists
    if ([filemgr fileExistsAtPath: filePath] == YES){
        NSLog(@"File exists");
        
    }else {
        NSLog (@"File not found, file will be created");
        return NULL;
    }
    
    return [filePath fileSystemRepresentation];
#endif
}

const char * GetGamePath(void){
    
    //if( sharedData_ == nil ){
    //    return nil;
    // }
    //NSString *path = sharedData_.selected_file;
    //return [path cStringUsingEncoding:1];
    return currentGamePath;;
}

const char * GetStateSavePath(void){
    BOOL isDir;
    NSFileManager *filemgr;
    filemgr = [NSFileManager defaultManager];
    NSString * fileName = @"state/";
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent: fileName];
    NSLog(@"full path name: %@", filePath);
    
    
    NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *dirName = [docDir stringByAppendingPathComponent:@"state"];
    
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if(![fm fileExistsAtPath:dirName isDirectory:&isDir])
    {
        if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES attributes:nil error:nil])
            NSLog(@"Directory Created");
        else
            NSLog(@"Directory Creation Failed");
    }
    else
        NSLog(@"Directory Already Exist");
    
    return [filePath fileSystemRepresentation];
}

const char * GetMemoryPath(void){
    BOOL isDir;
    NSFileManager *filemgr;
    filemgr = [NSFileManager defaultManager];
    NSString * fileName = @"backup/memory.bin";
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent: fileName];
    NSLog(@"full path name: %@", filePath);
    
    
    NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *dirName = [docDir stringByAppendingPathComponent:@"backup"];
    
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if(![fm fileExistsAtPath:dirName isDirectory:&isDir])
    {
        if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES attributes:nil error:nil])
            NSLog(@"Directory Created");
        else
            NSLog(@"Directory Creation Failed");
    }
    else
        NSLog(@"Directory Already Exist");
    
    // check if file exists
    if ([filemgr fileExistsAtPath: filePath] == YES){
        NSLog(@"File exists");
        
    }else {
        NSLog (@"File not found, file will be created");
    }
    
    return [filePath fileSystemRepresentation];
}

int GetCartridgeType(void){
    return _cart;
}

int GetVideoInterface(void){
    return 0;
}

int GetEnableFPS(void){
    if( _fps == YES )
        return 1;
    
    return 0;
}

int GetIsRotateScreen(void) {
    if( _rotate_screen == YES )
        return 1;
    
    return 0;
}

int GetEnableFrameSkip(void){
    if( _frame_skip == YES ){
        return 1;
    }
    return 0;
}

int GetUseNewScsp(void){
    return 1; //_sound_engine;
}

int GetVideFilterType(void){
    return _filter;
}

int GetResolutionType(void){
    NSLog (@"GetResolutionType %d",_rendering_resolution);
    return _rendering_resolution;
}

const char * GetCartridgePath(void){
    BOOL isDir;
    NSFileManager *filemgr;
    filemgr = [NSFileManager defaultManager];
    NSString * fileName = @"cart/invalid.ram";
    
    switch(_cart) {
        case CART_NONE:
            fileName = @"cart/none.ram";
            break;
        case CART_PAR:
            fileName = @"cart/par.ram";
            break;
        case CART_BACKUPRAM4MBIT:
            fileName = @"cart/backup4.ram";
            break;
        case CART_BACKUPRAM8MBIT:
            fileName = @"cart/backup8.ram";
            break;
        case CART_BACKUPRAM16MBIT:
            fileName = @"cart/backup16.ram";
            break;
        case CART_BACKUPRAM32MBIT:
            fileName = @"cart/backup32.ram";
            break;
        case CART_DRAM8MBIT:
            fileName = @"cart/dram8.ram";
            break;
        case CART_DRAM32MBIT:
            fileName = @"cart/dram32.ram";
            break;
        case CART_NETLINK:
            fileName = @"cart/netlink.ram";
            break;
        case CART_ROM16MBIT:
            fileName = @"cart/rom16.ram";
            break;
        default:
            fileName = @"cart/invalid.ram";
            break;
    }
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent: fileName];
    NSLog(@"full path name: %@", filePath);
    
    
    NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *dirName = [docDir stringByAppendingPathComponent:@"cart"];
    
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if(![fm fileExistsAtPath:dirName isDirectory:&isDir])
    {
        if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES attributes:nil error:nil])
            NSLog(@"Directory Created");
        else
            NSLog(@"Directory Creation Failed");
    }
    else
        NSLog(@"Directory Already Exist");
    
    // check if file exists
    if ([filemgr fileExistsAtPath: filePath] == YES){
        NSLog(@"File exists");
        
    }else {
        NSLog (@"File not found, file will be created");
    }
    return [filePath fileSystemRepresentation];
}

int GetPlayer2Device(void){
    return -1;
}

NSString* YSGetBackupDevicelist(){
    BackupManager * i = BackupManager::getInstance();
    string jsonstr;
    i->getDevicelist(jsonstr);
    NSString *objcString = [NSString stringWithUTF8String:jsonstr.c_str()];
    return objcString;
}

NSString* YSGetBackupFilelist( int deviceid ){
    BackupManager * i = BackupManager::getInstance();
    string jsonstr;
    i->getFilelist(deviceid,jsonstr);
    NSString *objcString = [NSString stringWithUTF8String:jsonstr.c_str()];
    return objcString;
}

int YSDeleteBackupFile( int index ){
    BackupManager * i = BackupManager::getInstance();
    string jsonstr;
    return i->deletefile(index);
}

NSString* YSGetBackupFile( int index ){
    BackupManager * i = BackupManager::getInstance();
    string jsonstr;
    i->getFile(index,jsonstr);
    NSString *objcString = [NSString stringWithUTF8String:jsonstr.c_str()];
    return objcString;
}

int YSPutFile( NSString* jsonstr  ){
    const char *cString = [jsonstr UTF8String];
    if (cString == NULL) return -1;
    BackupManager * i = BackupManager::getInstance();
    int rtn = i->putFile(string(cString));
    return rtn;
}

int YSCopy( int target, int file  ){
    BackupManager * i = BackupManager::getInstance();
    return i->copy(target,file);
}

void YSUpdateCheat(NSArray* stringArray) {
    if (stringArray == nil || [stringArray count] == 0) {
        CheatClearCodes();
        return;
    }
    
    int stringCount = (int)[stringArray count];
    int index = 0;
    CheatClearCodes();
    
    for (int i = 0; i < stringCount; i++) {
        NSString* string = [stringArray objectAtIndex:i];
        if (string == nil) {
            continue;
        }
        const char* rawString = [string UTF8String];
        index = CheatAddARCode(rawString);
        CheatEnableCode(index);
    }
    // CheatDoPatches(); will call at Vblank-in
    return;
}

NSString* YSGetCurrentGameCode() {
    const char *gameCode = Cs2GetCurrentGmaecode();
    if (gameCode == NULL) {
        return nil;
    }
    NSString *nsGameCode = [NSString stringWithUTF8String:gameCode];
    return nsGameCode;
}

} // Close extern "C" block temporarily

// Import Swift generated header for RetroAchievements bridge
// Try different possible Swift header names
#if __has_include("uoyabause-Swift.h")
  #import "uoyabause-Swift.h"
#elif __has_include("YabaSnashiro-Swift.h")
  #import "YabaSnashiro-Swift.h"
#elif __has_include("YabaSnashiro_Lite-Swift.h")
  #import "YabaSnashiro_Lite-Swift.h"
#else
  #warning "Could not find Swift bridging header - RetroAchievements bridge may not work"
  // Define forward declarations to prevent compilation errors
  @class RetroAchievementsBridge;
#endif

extern "C" {

// RetroAchievements integration functions
#include <dispatch/dispatch.h>

// ---------------------------------------------------------------------------
// Standalone backup RAM access (no emulation running).
// ---------------------------------------------------------------------------

int YSBupStandaloneOpen(const char *buppath, const char *cartpath, int carttype) {
    return YabBupStandaloneOpen(buppath, cartpath, carttype);
}

void YSBupStandaloneClose(void) {
    YabBupStandaloneClose();
}

int YSBupStandaloneList(int deviceId, YSBupSave *buffer, int maxCount) {
    int numsaves = 0;
    saveinfo_struct *saves;
    int i;

    if (buffer == NULL || maxCount <= 0) {
        return -1;
    }
    // BupGetSaveList mallocs the array; the caller owns it (see BackupManager.cpp).
    saves = BupGetSaveList((u32)deviceId, &numsaves);
    if (saves == NULL) {
        return 0;
    }
    if (numsaves > maxCount) {
        numsaves = maxCount;
    }
    for (i = 0; i < numsaves; i++) {
        memcpy(buffer[i].filename, saves[i].filename, 12);
        memcpy(buffer[i].comment, saves[i].comment, 11);
        buffer[i].language  = saves[i].language;
        buffer[i].year      = saves[i].year;
        buffer[i].month     = saves[i].month;
        buffer[i].day       = saves[i].day;
        buffer[i].hour      = saves[i].hour;
        buffer[i].minute    = saves[i].minute;
        buffer[i].week      = saves[i].week;
        buffer[i].datasize  = saves[i].datasize;
        buffer[i].blocksize = saves[i].blocksize;
    }
    free(saves);
    return numsaves;
}

int YSBupStandaloneStatus(int deviceId, unsigned int *totalSize, unsigned int *freeSize,
                          unsigned int *totalBlock, unsigned int *freeBlock) {
    devicestatus_struct status;
    if (BiosBUPStatusMem(deviceId, &status) != 0) {
        return -1;
    }
    if (totalSize)  *totalSize  = status.totalsize;
    if (freeSize)   *freeSize   = status.freesize;
    if (totalBlock) *totalBlock = status.totalblock;
    if (freeBlock)  *freeBlock  = status.freeblock;
    return 0;
}

int YSBupStandaloneDelete(int deviceId, const char *savename) {
    if (savename == NULL) {
        return -1;
    }
    // BupDeleteSave returns 0 on success, negative otherwise.
    return BupDeleteSave((u32)deviceId, savename);
}

int YSBupStandaloneCopy(int srcDeviceId, int dstDeviceId, const char *savename) {
    // BupCopySave is a stub in bios.c, so copy is export + import.
    saveinfo_struct *saves;
    saveinfo_struct header;
    int numsaves = 0;
    int i;
    int found = 0;
    char *buf = NULL;
    int bufsize = 0;
    int result;

    if (savename == NULL) {
        return -1;
    }

    saves = BupGetSaveList((u32)srcDeviceId, &numsaves);
    if (saves == NULL) {
        return -1;
    }
    for (i = 0; i < numsaves; i++) {
        if (strncmp(saves[i].filename, savename, 11) == 0) {
            header = saves[i];
            found = 1;
            break;
        }
    }
    free(saves);
    if (!found) {
        return -1;
    }

    // BiosBUPExport mallocs *buf; the caller owns it (see BackupManager.cpp).
    if (BiosBUPExport((u32)srcDeviceId, savename, &buf, &bufsize) != 0) {
        return -1;
    }

    result = BiosBUPImport((u32)dstDeviceId, &header, buf, bufsize);
    free(buf);
    if (result == 0) {
        return 0;
    }
    // BiosBUPImport returns 4 when the save does not fit in the free space and
    // 8 when no free block run could be found; both mean "destination full".
    if (result == 4 || result == 8) {
        return -2;
    }
    return -1;
}

int YSBupStandaloneCreateForTest(int deviceId, const char *name, const char *comment,
                                 const void *data, int dataSize) {
    saveinfo_struct header;
    if (name == NULL || comment == NULL || data == NULL || dataSize <= 0) {
        return -1;
    }
    memset(&header, 0, sizeof(header));
    strncpy(header.filename, name, 11);
    strncpy(header.comment, comment, 10);
    header.language = 0;
    // Only "date" is stored in backup RAM; year/month/day/hour/minute/week are
    // derived from it when reading back. This value decodes to 1998-05-12 09:30
    // (minutes since the Saturn BUP epoch).
    header.date = 9657210u;
    header.year = 18;      /* 1998 */
    header.month = 5;
    header.day = 12;
    header.hour = 9;
    header.minute = 30;
    header.week = 2;
    header.datasize = (u32)dataSize;
    header.blocksize = 0;
    return BiosBUPImport((u32)deviceId, &header, (const char *)data, dataSize) == 0 ? 0 : -1;
}

int YSBupStandaloneExport(int deviceId, const char *savename,
                          void **buffer, int *size) {
    char *buf = NULL;
    int bufsize = 0;

    if (savename == NULL || buffer == NULL || size == NULL) {
        return -1;
    }
    if (BiosBUPExport((u32)deviceId, savename, &buf, &bufsize) != 0) {
        return -1;
    }
    *buffer = buf;
    *size = bufsize;
    return 0;
}

int YSBupStandaloneImport(int deviceId, const char *name, const char *comment,
                          unsigned char language, unsigned int saturnDate,
                          const void *data, int dataSize) {
    saveinfo_struct header;
    int result;

    if (name == NULL || data == NULL || dataSize <= 0) {
        return -1;
    }

    memset(&header, 0, sizeof(header));
    strncpy(header.filename, name, 11);
    strncpy(header.comment, comment == NULL ? "" : comment, 10);
    header.language = language;
    // BiosBUPImport only writes filename, comment, language, date and datasize
    // into backup RAM; the y/m/d/h/m/week fields are derived from "date" when
    // the save is listed back, so they do not need to be populated here.
    header.date = saturnDate;
    header.datasize = (u32)dataSize;
    header.blocksize = 0;

    result = BiosBUPImport((u32)deviceId, &header, (const char *)data, dataSize);
    if (result == 0) {
        return 0;
    }
    if (result == 4 || result == 8) {
        return -2;
    }
    return -1;
}

unsigned int YSBupEncodeDate(int year, int month, int day, int hour, int minute) {
    return YabBupEncodeDate(year, month, day, hour, minute);
}

// Global state for RetroAchievements
static BOOL ra_initialized = NO;
static BOOL ra_user_logged_in = NO;
static BOOL ra_hardcore_enabled = NO;
static BOOL ra_paused = NO;
static char ra_username[256] = {0};
static char ra_token[256] = {0};
static char ra_rich_presence[512] = {0};

// HTTP request callback for native layer
typedef void (*http_request_callback_t)(const char* response, const char* error, void* userdata);

struct http_request_data {
    http_request_callback_t callback;
    void* userdata;
};

// Bridge to Swift HTTP implementation
static void perform_http_request(const char* url, const char* post_data, http_request_callback_t callback, void* userdata) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* nsUrl = [NSString stringWithUTF8String:url];
        NSString* nsPostData = post_data ? [NSString stringWithUTF8String:post_data] : nil;
        
        // Call Swift implementation via bridge class
        [RetroAchievementsBridge performHTTPRequest:nsUrl postData:nsPostData completion:^(NSString* response, NSString* error) {
            if (callback) {
                const char* responseStr = response ? [response UTF8String] : NULL;
                const char* errorStr = error ? [error UTF8String] : NULL;
                callback(responseStr, errorStr, userdata);
            }
        }];
    });
}

// RetroAchievements progress serialization (iOS implementation)
size_t YabauseRA_GetProgressSize() {
    // Return minimum size needed for basic state serialization
    return 64;
}

int YabauseRA_SerializeProgress(uint8_t* buffer, size_t buffer_size) {
    // Use iOS implementation directly
    if (buffer != NULL && buffer_size >= 64 && ra_initialized) {
        // Version header (4 bytes)
        buffer[0] = 'R';
        buffer[1] = 'A';
        buffer[2] = 0x01; // Version 1
        buffer[3] = 0x00;
        
        // User login state (1 byte)
        buffer[4] = ra_user_logged_in ? 1 : 0;
        
        // Hardcore mode state (1 byte)
        buffer[5] = ra_hardcore_enabled ? 1 : 0;
        
        // Reserved bytes
        memset(&buffer[6], 0, buffer_size - 6);
        
        return 1;
    }
    return 0;
}

int YabauseRA_DeserializeProgress(const uint8_t* buffer, size_t buffer_size) {
    // Use iOS implementation directly
    if (buffer != NULL && buffer_size >= 6) {
        // Check version header
        if (buffer[0] == 'R' && buffer[1] == 'A' && buffer[2] == 0x01) {
            // Restore user login state
            ra_user_logged_in = (buffer[4] != 0);
            
            // Restore hardcore mode state
            ra_hardcore_enabled = (buffer[5] != 0);
            
            return 1; // Success
        }
    }
    return 0; // Failure
}


// YabauseRA_CreateAchievementList and YabauseRA_DestroyAchievementList
// are implemented in yabause_ra_integration_cwrapper.cpp
// No implementation needed here - C++ functions will be linked directly

// NOTICE: All iOS RetroAchievements functions have been REMOVED
// The actual implementation is now in yabause_ra_integration_cwrapper.cpp
// which provides the proper rcheevos integration following the official guide:
// https://github.com/RetroAchievements/rcheevos/wiki/rc_client-integration

// All YabauseRA_* functions are now provided by the C++ wrapper in:
// - yabause_ra_integration_cwrapper.h (declarations)  
// - yabause_ra_integration_cwrapper.cpp (implementation)
// 
// These functions use the official rcheevos library and follow the integration guide.
// The iOS-specific direct API implementation has been completely removed.

// Registers the standalone rc_hash cdreader; implemented in the shared core
// (yabause_ra_integration.cpp).
void YabauseRA_InitHashCdReader(void);

int YabauseRA_GenerateGameHash(const char* path, char* buffer, int bufferSize) {
    if (path == NULL || buffer == NULL || bufferSize < 33) {
        return 0;
    }
    // Register the standalone cdreader (idempotent)
    YabauseRA_InitHashCdReader();
    char hash[33];
    if (rc_hash_generate_from_file(hash, RC_CONSOLE_SATURN, path)) {
        strncpy(buffer, hash, bufferSize);
        buffer[bufferSize - 1] = '\0';
        return 1;
    }
    return 0;
}

const char* YabauseRA_GetUserApiToken(void) {
    YabauseRA::Integration* ra = YabauseRA::Integration::getInstance();
    if (ra == NULL) {
        return NULL;
    }
    const rc_client_user_t* user = ra->getUserInfo();
    if (user == NULL || user->token == NULL || strlen(user->token) == 0) {
        return NULL;
    }
    return user->token;
}

} // extern "C"
