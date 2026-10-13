/// @file YabaRA.cpp
/// @brief RetroAchievements for YabaSanshiro (see YabaRA.h).

#include "YabaRA.h"

#include <switch.h>

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <strings.h>
#include <deque>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <vector>

#include <SDL_mixer.h>
#include <curl/curl.h>
#include <nlohmann/json.hpp>

#include "rc_client.h"
#include "rc_hash.h"

#include <libchdr/cdrom.h>
#include <libchdr/chd.h>

#include "TicoLogger.h"
#include "TicoSession.h"
#include "deps/stb/stb_image.h"
#include "overlay/imgui_overlay.h"

extern "C" {
#include "memory.h"
}

namespace {

using SwitchFrontend::RAAlerts::Notification;

constexpr uint32_t kSaturnConsoleId = 39; // RC_CONSOLE_SATURN
constexpr const char* kBadgeDir = "sdmc:/tico/assets/ra/";

rc_client_t* s_client = nullptr;
bool s_hardcore = false;
bool s_badges = true;
Mix_Chunk* s_trophy = nullptr;
std::string s_disc;

// ---------------------------------------------------------------------------
// Toasts: pushed on the main thread, drawn (and expired) on the drawing thread

std::mutex s_toast_mutex;
std::vector<Notification> s_pending;
std::vector<Notification> s_shown; // drawing thread only
std::map<std::string, ImTextureID> s_badges_uploaded; // drawing thread only

void Push(const std::string& title, const std::string& description, const std::string& badge) {
    Notification n;
    n.title = title;
    n.description = description;
    n.badge_name = s_badges ? badge : "ra_icon";
    std::lock_guard<std::mutex> lock(s_toast_mutex);
    if (s_pending.size() >= 5)
        s_pending.erase(s_pending.begin());
    s_pending.push_back(std::move(n));
}

void Collect() {
    std::lock_guard<std::mutex> lock(s_toast_mutex);
    for (Notification& n : s_pending) {
        if (s_shown.size() >= 5)
            s_shown.erase(s_shown.begin());
        s_shown.push_back(std::move(n));
    }
    s_pending.clear();
}

// A downloaded badge, uploaded the first time a toast shows it.
ImTextureID BadgeTexture(const std::string& badge) {
    const auto it = s_badges_uploaded.find(badge);
    if (it != s_badges_uploaded.end())
        return it->second;
    const std::string path = kBadgeDir + badge + ".png";
    int w = 0, h = 0, channels = 0;
    unsigned char* pixels = stbi_load(path.c_str(), &w, &h, &channels, 4);
    if (!pixels)
        return ImTextureID_Invalid;
    const ImTextureID texture =
        static_cast<ImTextureID>(SwitchFrontend::ImGuiOverlay::CreateTexture(pixels, w, h));
    stbi_image_free(pixels);
    if (texture != ImTextureID_Invalid)
        s_badges_uploaded[badge] = texture;
    return texture;
}

// ---------------------------------------------------------------------------
// HTTP worker: rc_client's requests and badge downloads, off the main thread

struct Job {
    std::string url;
    std::string post_data;
    rc_client_server_callback_t callback = nullptr;
    void* callback_data = nullptr;
    bool badge = false;
};

std::mutex s_job_mutex;
std::condition_variable s_job_cond;
std::deque<Job> s_jobs;
bool s_worker_running = false;
Thread s_worker;
bool s_worker_created = false;

std::mutex s_answer_mutex;
std::vector<std::function<void()>> s_answers;

size_t CurlWrite(void* contents, size_t size, size_t count, void* user) {
    static_cast<std::string*>(user)->append(static_cast<char*>(contents), size * count);
    return size * count;
}

long Fetch(const std::string& url, const std::string& post_data, std::string& body) {
    CURL* curl = curl_easy_init();
    if (!curl)
        return 0;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    if (!post_data.empty())
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post_data.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, CurlWrite);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
    long status = 0;
    if (curl_easy_perform(curl) == CURLE_OK)
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    else
        status = 500;
    curl_easy_cleanup(curl);
    return status;
}

void DownloadBadge(const std::string& badge) {
    const std::string path = kBadgeDir + badge + ".png";
    struct stat status;
    if (stat(path.c_str(), &status) == 0)
        return;
    std::string body;
    if (Fetch("https://media.retroachievements.org/Badge/" + badge + ".png", "", body) != 200 ||
        body.empty())
        return;
    mkdir("sdmc:/tico/assets", 0777);
    mkdir("sdmc:/tico/assets/ra", 0777);
    if (FILE* fp = fopen(path.c_str(), "wb")) {
        fwrite(body.data(), 1, body.size(), fp);
        fclose(fp);
    }
}

void WorkerEntry(void*) {
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(s_job_mutex);
            s_job_cond.wait(lock, [] { return !s_jobs.empty() || !s_worker_running; });
            if (!s_worker_running && s_jobs.empty())
                break;
            job = std::move(s_jobs.front());
            s_jobs.pop_front();
        }
        if (job.badge) {
            DownloadBadge(job.url);
            continue;
        }
        std::string body;
        const long status = Fetch(job.url, job.post_data, body);
        std::lock_guard<std::mutex> lock(s_answer_mutex);
        s_answers.push_back([job, status, body]() {
            rc_api_server_response_t response;
            std::memset(&response, 0, sizeof(response));
            response.body = body.c_str();
            response.body_length = body.size();
            response.http_status_code = status;
            if (job.callback)
                job.callback(&response, job.callback_data);
        });
    }
}

void StartWorker() {
    s_worker_running = true;
    std::memset(&s_worker, 0, sizeof(s_worker));
    if (R_SUCCEEDED(threadCreate(&s_worker, WorkerEntry, nullptr, nullptr, 0x40000, 0x2C, -2))) {
        if (R_SUCCEEDED(threadStart(&s_worker))) {
            s_worker_created = true;
            return;
        }
        threadClose(&s_worker);
    }
    s_worker_running = false;
}

void StopWorker() {
    if (!s_worker_created)
        return;
    {
        std::lock_guard<std::mutex> lock(s_job_mutex);
        s_worker_running = false;
    }
    s_job_cond.notify_one();
    threadWaitForExit(&s_worker);
    threadClose(&s_worker);
    s_worker_created = false;
}

void Queue(Job job) {
    {
        std::lock_guard<std::mutex> lock(s_job_mutex);
        s_jobs.push_back(std::move(job));
    }
    s_job_cond.notify_one();
}

void RunAnswers() {
    std::vector<std::function<void()>> answers;
    {
        std::lock_guard<std::mutex> lock(s_answer_mutex);
        answers.swap(s_answers);
    }
    for (auto& answer : answers)
        answer();
}

// ---------------------------------------------------------------------------
// rc_client

uint32_t RC_CCONV ReadMemory(uint32_t address, uint8_t* buffer, uint32_t count, rc_client_t*) {
    // Saturn: 0x000000-0x0FFFFF Low WRAM, 0x100000-0x1FFFFF High WRAM
    if (address + count <= 0x100000) {
        if (LowWram)
            std::memcpy(buffer, LowWram + address, count);
        return count;
    }
    if (address >= 0x100000 && address + count <= 0x200000) {
        if (HighWram)
            std::memcpy(buffer, HighWram + (address - 0x100000), count);
        return count;
    }
    return 0;
}

void RC_CCONV ServerCall(const rc_api_request_t* request, rc_client_server_callback_t callback,
                         void* callback_data, rc_client_t*) {
    Job job;
    job.url = request->url;
    if (request->post_data)
        job.post_data = request->post_data;
    job.callback = callback;
    job.callback_data = callback_data;
    Queue(std::move(job));
}

void QueueBadgeDownloads() {
    if (!s_badges)
        return;
    rc_client_achievement_list_t* list = rc_client_create_achievement_list(
        s_client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE_AND_UNOFFICIAL,
        RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_PROGRESS);
    if (!list)
        return;
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        for (uint32_t a = 0; a < list->buckets[b].num_achievements; a++) {
            const rc_client_achievement_t* achievement = list->buckets[b].achievements[a];
            if (!achievement || !achievement->badge_name[0])
                continue;
            Job job;
            job.url = achievement->badge_name;
            job.badge = true;
            Queue(std::move(job));
        }
    }
    rc_client_destroy_achievement_list(list);
}

void OnEvent(const rc_client_event_t* event, rc_client_t*) {
    switch (event->type) {
    case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
        if (event->achievement) {
            LOG_INFO("RA", "Achievement unlocked: %s", event->achievement->title);
            Push(event->achievement->title, event->achievement->description,
                 event->achievement->badge_name);
            if (s_trophy)
                Mix_PlayChannel(-1, s_trophy, 0);
        }
        break;
    case RC_CLIENT_EVENT_GAME_COMPLETED:
        Push("Game Mastered!", "All achievements unlocked!", "ra_icon");
        if (s_trophy)
            Mix_PlayChannel(-1, s_trophy, 0);
        break;
    case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
        if (event->leaderboard)
            Push("Leaderboard", event->leaderboard->title, "ra_icon");
        break;
    default:
        break;
    }
}

void OnGameLoaded(int result, const char* error, rc_client_t* client, void*) {
    if (result != RC_OK) {
        LOG_WARN("RA", "identify failed: %s", error ? error : "unknown");
        Push("RetroAchievements", std::string("Identify failed: ") + (error ? error : "unknown"),
             "ra_icon");
        return;
    }
    const rc_client_game_t* game = rc_client_get_game_info(client);
    const std::string title = game && game->title ? game->title : "Unknown Title";
    LOG_INFO("RA", "playing %s", title.c_str());
    Push("RetroAchievements", "Playing: " + title, "ra_icon");
    QueueBadgeDownloads();
}

void OnLogin(int result, const char* error, rc_client_t* client, void*) {
    if (result != RC_OK) {
        LOG_ERROR("RA", "login failed: %s", error ? error : "unknown");
        Push("RetroAchievements", std::string("Login failed: ") + (error ? error : "unknown"),
             "ra_icon");
        return;
    }
    rc_client_begin_identify_and_load_game(client, kSaturnConsoleId, s_disc.c_str(), nullptr, 0,
                                           OnGameLoaded, nullptr);
}


// Games in .chd: rcheevos reads .cue, .bin and .iso itself, CHD through
// libchdr here, as tico-genesisplusgx does for its Sega CD discs (the
// tracks laid out one after another, each padded to CD_TRACK_PADDING
// frames, the pregap stored only when its type is 'V').
rc_hash_cdreader_t s_defaultCdReader;

struct ChdTrack
{
    chd_file *chd = nullptr;
    uint32_t hunkBytes = 0;
    uint64_t offset = 0;      // byte offset of the track's first sector
    uint32_t headerBytes = 0; // 16 for MODE1_RAW, 24 for MODE2_RAW, 0 cooked
    uint32_t dataBytes = 2048;
    std::vector<uint8_t> hunk;
    int64_t hunkNum = -1;
};

struct DiscHandle
{
    bool chd = false;
    void *inner = nullptr; // ChdTrack, or the default reader's handle
};

ChdTrack *OpenChdTrack(const char *path, uint32_t track)
{
    chd_file *chd = nullptr;
    if (chd_open(path, CHD_OPEN_READ, nullptr, &chd) != CHDERR_NONE)
        return nullptr;
    const chd_header *head = chd_get_header(chd);
    if (!head || !head->hunkbytes || head->hunkbytes % CD_FRAME_SIZE)
    {
        chd_close(chd);
        return nullptr;
    }

    uint64_t sectors = 0;
    for (uint32_t index = 0; index < 99; ++index)
    {
        char metadata[256] = {};
        int number = 0, frames = 0, pregap = 0, postgap = 0;
        char type[16] = {}, subtype[16] = {}, pgtype[16] = {}, pgsub[16] = {};
        if (chd_get_metadata(chd, CDROM_TRACK_METADATA2_TAG, index, metadata, sizeof(metadata), 0, 0, 0) == CHDERR_NONE)
        {
            if (sscanf(metadata, CDROM_TRACK_METADATA2_FORMAT, &number, type, subtype, &frames, &pregap,
                       pgtype, pgsub, &postgap) != 8)
                break;
        }
        else if (chd_get_metadata(chd, CDROM_TRACK_METADATA_TAG, index, metadata, sizeof(metadata), 0, 0, 0) == CHDERR_NONE)
        {
            if (sscanf(metadata, CDROM_TRACK_METADATA_FORMAT, &number, type, subtype, &frames) != 4)
                break;
        }
        else
            break;
        if (pgtype[0] != 'V')
            pregap = 0; // not stored in the file

        const bool audio = !strcmp(type, "AUDIO");
        const bool wanted = track == RC_HASH_CDTRACK_FIRST_DATA ? !audio : number == (int)track;
        if (wanted)
        {
            ChdTrack *out = new ChdTrack();
            out->chd = chd;
            out->hunkBytes = head->hunkbytes;
            out->offset = (sectors + (uint64_t)pregap) * CD_FRAME_SIZE;
            out->headerBytes = !strcmp(type, "MODE1_RAW") ? 16 : !strcmp(type, "MODE2_RAW") ? 24 : 0;
            out->dataBytes = audio ? 2352 : 2048;
            out->hunk.resize(head->hunkbytes);
            return out;
        }
        sectors += ((frames + CD_TRACK_PADDING - 1) / CD_TRACK_PADDING) * CD_TRACK_PADDING;
    }
    chd_close(chd);
    return nullptr;
}

size_t ReadChdSector(ChdTrack *track, uint32_t sector, void *buffer, size_t requested)
{
    uint8_t *out = (uint8_t *)buffer;
    size_t total = 0;
    while (requested > 0)
    {
        const uint64_t at = track->offset + (uint64_t)sector * CD_FRAME_SIZE + track->headerBytes;
        const int64_t hunkNum = (int64_t)(at / track->hunkBytes);
        if (hunkNum != track->hunkNum)
        {
            if (chd_read(track->chd, (uint32_t)hunkNum, track->hunk.data()) != CHDERR_NONE)
                return total;
            track->hunkNum = hunkNum;
        }
        const size_t count = std::min<size_t>(requested, track->dataBytes);
        memcpy(out + total, track->hunk.data() + at % track->hunkBytes, count);
        total += count;
        requested -= count;
        ++sector;
    }
    return total;
}

void *RC_CCONV DiscOpenTrack(const char *path, uint32_t track, const rc_hash_iterator_t *iterator)
{
    DiscHandle *handle = new DiscHandle();
    const size_t length = strlen(path);
    handle->chd = length > 4 && !strcasecmp(path + length - 4, ".chd");
    handle->inner = handle->chd ? (void *)OpenChdTrack(path, track)
                                : s_defaultCdReader.open_track_iterator(path, track, iterator);
    if (!handle->inner)
    {
        delete handle;
        return nullptr;
    }
    return handle;
}

size_t RC_CCONV DiscReadSector(void *track, uint32_t sector, void *buffer, size_t requested)
{
    DiscHandle *handle = (DiscHandle *)track;
    if (!handle)
        return 0;
    if (handle->chd)
        return ReadChdSector((ChdTrack *)handle->inner, sector, buffer, requested);
    return s_defaultCdReader.read_sector(handle->inner, sector, buffer, requested);
}

void RC_CCONV DiscCloseTrack(void *track)
{
    DiscHandle *handle = (DiscHandle *)track;
    if (!handle)
        return;
    if (handle->chd)
    {
        ChdTrack *chdTrack = (ChdTrack *)handle->inner;
        chd_close(chdTrack->chd);
        delete chdTrack;
    }
    else
        s_defaultCdReader.close_track(handle->inner);
    delete handle;
}

uint32_t RC_CCONV DiscFirstTrackSector(void *track)
{
    DiscHandle *handle = (DiscHandle *)track;
    if (!handle)
        return 0;
    // a CHD track's sectors count from its own start
    return handle->chd ? 0 : s_defaultCdReader.first_track_sector(handle->inner);
}

void UseDiscReader(rc_client_t *client)
{
    rc_hash_get_default_cdreader(&s_defaultCdReader);
    rc_hash_callbacks_t callbacks = {};
    callbacks.cdreader.open_track_iterator = DiscOpenTrack;
    callbacks.cdreader.read_sector = DiscReadSector;
    callbacks.cdreader.close_track = DiscCloseTrack;
    callbacks.cdreader.first_track_sector = DiscFirstTrackSector;
    rc_client_set_hash_callbacks(client, &callbacks);
}
} // namespace

// Save-state hooks the core calls (memory.c, RACH chunk). Upstream implements
// them in retroachievements/, which this port replaces with its own rc_client.
extern "C" size_t YabauseRA_GetProgressSize(void) {
    return s_client ? rc_client_progress_size(s_client) : 0;
}

extern "C" int YabauseRA_SerializeProgress(uint8_t* buffer, size_t buffer_size) {
    if (!s_client)
        return 0;
    return rc_client_serialize_progress_sized(s_client, buffer, buffer_size) == RC_OK ? 1 : 0;
}

extern "C" int YabauseRA_DeserializeProgress(const uint8_t* buffer, size_t buffer_size) {
    if (!s_client)
        return 0;
    // NULL/0 resets progress (a state saved without achievement data)
    return rc_client_deserialize_progress_sized(s_client, buffer, buffer_size) == RC_OK ? 1 : 0;
}

namespace YabaRA {

void Init(const std::string& disc_path) {
    // the account tico sealed for this launch, else the older accounts file
    const tico::Session& session = tico::CurrentSession();
    bool enabled = false;
    std::string username, token, password;
    if (session.valid) {
        enabled = session.raEnabled;
        username = session.raUsername;
        token = session.raToken;
        s_hardcore = session.raHardcore;
        s_badges = session.raBadges;
    } else {
        std::ifstream file("sdmc:/tico/config/accounts.jsonc");
        if (file.is_open()) {
            const nlohmann::json j = nlohmann::json::parse(file, nullptr, false, true);
            if (!j.is_discarded() && j.is_object()) {
                enabled = j.value("ra_enabled", false);
                username = j.value("ra_username", "");
                token = j.value("ra_token", "");
                password = j.value("ra_password", "");
                s_hardcore = j.value("ra_hardcore_mode", false);
            }
        }
    }
    if (!enabled || username.empty() || (token.empty() && password.empty()))
        return;

    s_client = rc_client_create(ReadMemory, ServerCall);
    if (!s_client)
        return;
    UseDiscReader(s_client);
    s_disc = disc_path;
    s_trophy = Mix_LoadWAV("romfs:/assets/trophy.mp3");
    rc_client_set_event_handler(s_client, OnEvent);
    rc_client_set_hardcore_enabled(s_client, s_hardcore);
    StartWorker();
    LOG_INFO("RA", "logging in as %s", username.c_str());
    if (!token.empty())
        rc_client_begin_login_with_token(s_client, username.c_str(), token.c_str(), OnLogin, nullptr);
    else
        rc_client_begin_login_with_password(s_client, username.c_str(), password.c_str(), OnLogin,
                                            nullptr);
}

void Shutdown() {
    StopWorker();
    if (s_client) {
        rc_client_destroy(s_client);
        s_client = nullptr;
    }
    if (s_trophy) {
        Mix_FreeChunk(s_trophy);
        s_trophy = nullptr;
    }
}

void DoFrame() {
    if (!s_client)
        return;
    RunAnswers();
    rc_client_do_frame(s_client);
}

void Idle() {
    if (!s_client)
        return;
    RunAnswers();
    rc_client_idle(s_client);
}

bool Active() {
    return s_client != nullptr;
}

bool Hardcore() {
    return s_client && rc_client_get_hardcore_enabled(s_client);
}

bool CanPause(int& seconds_remaining) {
    seconds_remaining = 0;
    if (!Hardcore())
        return true;
    uint32_t frames_remaining = 0;
    if (rc_client_can_pause(s_client, &frames_remaining))
        return true;
    seconds_remaining = static_cast<int>((frames_remaining + 59) / 60);
    if (seconds_remaining < 1)
        seconds_remaining = 1;
    return false;
}

SwitchFrontend::RAAlerts::Source AlertSource() {
    SwitchFrontend::RAAlerts::Source source;
    source.notifications = &s_shown;
    source.collect = Collect;
    source.badge_texture = BadgeTexture;
    return source;
}

} // namespace YabaRA
