/**
 * SPDX-FileCopyrightText: 2026 KDE Connect contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#include "mpriscontrolplugin-macos.h"

#include "plugin_mpriscontrol_debug.h"

#include <KPluginFactory>

#include <QMetaObject>
#include <QPointer>
#include <QProcess>
#include <QTemporaryFile>
#include <QTimer>
#include <QBuffer>
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDateTime>
#include <QFileInfo>
#include <QStandardPaths>

#include <cmath>
#include <dlfcn.h>
#include <algorithm>

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

K_PLUGIN_CLASS_WITH_JSON(MprisControlPlugin, "kdeconnect_mpriscontrol.json")

struct NowPlayingInfo {
    QString title;
    QString artist;
    QString album;
    qlonglong length = -1;
    qlonglong pos = 0;
    bool hasPosition = false;
    bool hasPlaybackRate = false;
    double playbackRate = 0.0;
    bool isPlaying = false;
    bool hasDescriptiveMetadata = false;
    bool hasUsefulMetadata = false;
    QByteArray artworkBytes;
    QString source;
    QString bundleIdentifier;
    QString contentItemIdentifier;
    qint64 processIdentifier = 0;
};

namespace
{
QString nowPlayingPlayer()
{
    return QStringLiteral("Now Playing");
}

constexpr int commandPlay = 0;
constexpr int commandPause = 1;
constexpr int commandTogglePlayPause = 2;
constexpr int commandNextTrack = 4;
constexpr int commandPreviousTrack = 5;
constexpr int pollIntervalMs = 1500;
constexpr int nowPlayingTimeoutMs = 1000;
constexpr int helperTimeoutMs = 500;
constexpr int appleScriptTimeoutMs = 900;
constexpr int processCleanupTimeoutMs = 100;
constexpr int mediaControlGetTimeoutMs = 500;
constexpr int mediaControlArtworkTimeoutMs = 1000;
constexpr int mediaControlCommandTimeoutMs = 500;
constexpr qsizetype maxAlbumArtBytes = 5 * 1024 * 1024;
constexpr double minimumPlayingRate = 0.01;

const QString keyPlayer = QStringLiteral("player");
const QString keyTitle = QStringLiteral("title");
const QString keyArtist = QStringLiteral("artist");
const QString keyAlbum = QStringLiteral("album");
const QString keyAlbumArtUrl = QStringLiteral("albumArtUrl");
const QString keyLength = QStringLiteral("length");
const QString keyPos = QStringLiteral("pos");
const QString keyIsPlaying = QStringLiteral("isPlaying");
const QString keyPlaybackRate = QStringLiteral("playbackRate");

template<typename T>
T loadSymbol(void *handle, const char *name)
{
    return handle ? reinterpret_cast<T>(dlsym(handle, name)) : nullptr;
}

QString cfStringToQString(CFTypeRef value)
{
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return {};
    }

    auto string = static_cast<CFStringRef>(value);
    const CFIndex length = CFStringGetLength(string);
    const CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    QByteArray buffer(maxSize, Qt::Uninitialized);
    if (!CFStringGetCString(string, buffer.data(), maxSize, kCFStringEncodingUTF8)) {
        return {};
    }

    return QString::fromUtf8(buffer.constData());
}

bool cfNumberToDouble(CFTypeRef value, double *number)
{
    return value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, number);
}

QByteArray cfDataToByteArray(CFTypeRef value)
{
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) {
        return {};
    }

    auto data = static_cast<CFDataRef>(value);
    const CFIndex length = CFDataGetLength(data);
    if (length <= 0 || length > maxAlbumArtBytes) {
        return {};
    }

    return QByteArray(reinterpret_cast<const char *>(CFDataGetBytePtr(data)), length);
}

qlonglong secondsToMilliseconds(double seconds, qlonglong fallback = 0)
{
    if (!std::isfinite(seconds) || seconds < 0) {
        return fallback;
    }
    return static_cast<qlonglong>(std::llround(seconds * 1000.0));
}

class MediaRemote
{
public:
    using GetNowPlayingInfo = void (*)(dispatch_queue_t, void (^)(CFDictionaryRef));
    using GetIsPlaying = void (*)(dispatch_queue_t, void (^)(Boolean));
    using SendCommand = Boolean (*)(int, CFDictionaryRef);

    static MediaRemote &self()
    {
        static MediaRemote instance;
        return instance;
    }

    bool canSendCommands() const
    {
        return m_sendCommand;
    }

    bool canReadNowPlayingInfo() const
    {
        return m_getNowPlayingInfo;
    }

    bool sendCommand(int command) const
    {
        if (!m_sendCommand) {
            return false;
        }
        return m_sendCommand(command, nullptr);
    }

    void getNowPlayingInfoAsync(void (^reply)(CFDictionaryRef)) const
    {
        if (!m_getNowPlayingInfo) {
            reply(nullptr);
            return;
        }

        m_getNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(CFDictionaryRef info) {
            reply(info);
        });
    }

    bool queryIsPlaying(bool *ok) const
    {
        *ok = false;
        if (!m_getIsPlaying) {
            return false;
        }

        __block Boolean playing = false;
        __block bool answered = false;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        m_getIsPlaying(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(Boolean isPlaying) {
            playing = isPlaying;
            answered = true;
            dispatch_semaphore_signal(semaphore);
        });

        if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, helperTimeoutMs * NSEC_PER_MSEC)) != 0 || !answered) {
            return false;
        }

        *ok = true;
        return playing;
    }

    CFStringRef keyTitle() const { return key(m_keyTitle); }
    CFStringRef keyArtist() const { return key(m_keyArtist); }
    CFStringRef keyAlbum() const { return key(m_keyAlbum); }
    CFStringRef keyDuration() const { return key(m_keyDuration); }
    CFStringRef keyElapsedTime() const { return key(m_keyElapsedTime); }
    CFStringRef keyPlaybackRate() const { return key(m_keyPlaybackRate); }
    CFStringRef keyArtworkData() const { return key(m_keyArtworkData); }

private:
    MediaRemote()
    {
        if (qEnvironmentVariableIsSet("KDECONNECT_DISABLE_MACOS_MEDIAREMOTE")) {
            qCWarning(KDECONNECT_PLUGIN_MPRISCONTROL) << "macOS MediaRemote disabled by KDECONNECT_DISABLE_MACOS_MEDIAREMOTE";
            return;
        }

        m_handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
        if (!m_handle) {
            qCWarning(KDECONNECT_PLUGIN_MPRISCONTROL) << "Could not load MediaRemote" << dlerror();
            return;
        }

        m_getNowPlayingInfo = loadSymbol<GetNowPlayingInfo>(m_handle, "MRMediaRemoteGetNowPlayingInfo");
        m_getIsPlaying = loadSymbol<GetIsPlaying>(m_handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        m_sendCommand = loadSymbol<SendCommand>(m_handle, "MRMediaRemoteSendCommand");

        m_keyTitle = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoTitle");
        m_keyArtist = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoArtist");
        m_keyAlbum = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoAlbum");
        m_keyDuration = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoDuration");
        m_keyElapsedTime = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoElapsedTime");
        m_keyPlaybackRate = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
        m_keyArtworkData = loadSymbol<CFStringRef *>(m_handle, "kMRMediaRemoteNowPlayingInfoArtworkData");

        if (!m_sendCommand) {
            qCWarning(KDECONNECT_PLUGIN_MPRISCONTROL) << "MediaRemote command symbol unavailable";
        }
        if (!m_getNowPlayingInfo) {
            qCWarning(KDECONNECT_PLUGIN_MPRISCONTROL) << "MediaRemote now-playing info symbol unavailable; metadata polling disabled";
        }
    }

    static CFStringRef key(CFStringRef *symbol)
    {
        return symbol ? *symbol : nullptr;
    }

    void *m_handle = nullptr;
    GetNowPlayingInfo m_getNowPlayingInfo = nullptr;
    GetIsPlaying m_getIsPlaying = nullptr;
    SendCommand m_sendCommand = nullptr;
    CFStringRef *m_keyTitle = nullptr;
    CFStringRef *m_keyArtist = nullptr;
    CFStringRef *m_keyAlbum = nullptr;
    CFStringRef *m_keyDuration = nullptr;
    CFStringRef *m_keyElapsedTime = nullptr;
    CFStringRef *m_keyPlaybackRate = nullptr;
    CFStringRef *m_keyArtworkData = nullptr;
};

NowPlayingInfo readNowPlayingInfo(CFDictionaryRef info)
{
    NowPlayingInfo result;
    if (!info || CFGetTypeID(info) != CFDictionaryGetTypeID() || CFDictionaryGetCount(info) == 0) {
        return result;
    }

    const auto value = [info](CFStringRef key) -> CFTypeRef {
        return key ? CFDictionaryGetValue(info, key) : nullptr;
    };

    result.title = cfStringToQString(value(MediaRemote::self().keyTitle()));
    result.artist = cfStringToQString(value(MediaRemote::self().keyArtist()));
    result.album = cfStringToQString(value(MediaRemote::self().keyAlbum()));

    double number = 0;
    if (cfNumberToDouble(value(MediaRemote::self().keyDuration()), &number)) {
        result.length = secondsToMilliseconds(number, -1);
    }
    if (cfNumberToDouble(value(MediaRemote::self().keyElapsedTime()), &number)) {
        result.pos = secondsToMilliseconds(number);
        result.hasPosition = true;
    }
    if (cfNumberToDouble(value(MediaRemote::self().keyPlaybackRate()), &number)) {
        result.hasPlaybackRate = true;
        result.playbackRate = number;
        result.isPlaying = number > minimumPlayingRate;
    }
    result.artworkBytes = cfDataToByteArray(value(MediaRemote::self().keyArtworkData()));

    result.hasDescriptiveMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.hasPosition
        || !result.artworkBytes.isEmpty();
    result.hasUsefulMetadata = result.hasDescriptiveMetadata || result.hasPlaybackRate;
    if (!result.hasDescriptiveMetadata && result.hasPlaybackRate && result.isPlaying) {
        result.title = nowPlayingPlayer();
    }
    if (result.hasUsefulMetadata) {
        result.source = QStringLiteral("MediaRemote");
    }
    return result;
}

NowPlayingInfo runAppleScript(const QString &script, const QString &source)
{
    NowPlayingInfo result;
    QProcess process;
    process.setProgram(QStringLiteral("/usr/bin/osascript"));
    process.setArguments({QStringLiteral("-l"), QStringLiteral("JavaScript"), QStringLiteral("-e"), script});
    process.start();
    if (!process.waitForFinished(appleScriptTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        process.waitForFinished(processCleanupTimeoutMs);
        return result;
    }

    const QJsonDocument document = QJsonDocument::fromJson(process.readAllStandardOutput().trimmed());
    if (!document.isObject()) {
        return result;
    }

    const QJsonObject object = document.object();
    result.title = object.value(keyTitle).toString();
    result.artist = object.value(keyArtist).toString();
    result.album = object.value(keyAlbum).toString();
    result.length = object.value(keyLength).toInteger(-1);
    result.pos = object.value(keyPos).toInteger(0);
    result.hasPosition = object.contains(keyPos);
    result.hasPlaybackRate = object.contains(keyIsPlaying);
    result.playbackRate = object.value(keyPlaybackRate).toDouble(object.value(keyIsPlaying).toBool(false) ? 1.0 : 0.0);
    result.isPlaying = object.value(keyIsPlaying).toBool(false);
    result.hasDescriptiveMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.hasPosition;
    result.hasUsefulMetadata = result.hasDescriptiveMetadata || result.hasPlaybackRate;
    if (result.hasUsefulMetadata) {
        result.source = object.value(QStringLiteral("source")).toString(source);
    }
    return result;
}

// One combined AppleScript query probes these scriptable players. durationMultiplier converts
// each app's native track duration to milliseconds. Artwork readers only run when that app is
// the active metadata source. Adding a player = adding a table entry.
struct ScriptablePlayer {
    const char *appName;
    double durationMultiplier;
    QByteArray (*artworkReader)();
};

QByteArray readMusicArtworkFallback();
QByteArray readSpotifyArtworkFallback();

static const ScriptablePlayer scriptablePlayers[] = {
    {"Music", 1000, &readMusicArtworkFallback},
    {"Spotify", 1, &readSpotifyArtworkFallback},
};

NowPlayingInfo queryAppleScriptFallbacks(const QString &preferredSource)
{
    static const QString script = QStringLiteral(R"JS(

  try {
    const app = Application(appName);
    app.includeStandardAdditions = true;
    if (!app.running()) return null;
    const state = String(app.playerState ? app.playerState() : '');
    const stateLower = state.toLowerCase();
    if (stateLower !== 'playing' && stateLower !== 'paused') return null;
    const track = app.currentTrack();
    const duration = Number(track.duration ? track.duration() : 0);
    const position = Number(app.playerPosition ? app.playerPosition() : 0);
    const item = {
      title: String(track.name ? track.name() : ''),
      artist: String(track.artist ? track.artist() : ''),
      album: String(track.album ? track.album() : ''),
      length: isFinite(duration) && duration > 0 ? Math.round(duration * durationMultiplier) : -1,
      pos: isFinite(position) && position > 0 ? Math.round(position * 1000) : 0,
      playbackRate: stateLower === 'playing' ? 1 : 0,
      isPlaying: stateLower === 'playing',
      source: 'AppleScript/' + appName
    };
    if (!item.title && !item.artist && !item.album && item.length < 0 && item.pos <= 0) return null;
    return item;
  } catch (e) { return null; }
}
const candidates = [%2].filter(Boolean);
const playing = candidates.filter(item => item.isPlaying);
const preferred = %1;
const preferredPaused = candidates.filter(item => item.source === preferred);
JSON.stringify(playing[0] || preferredPaused[0] || candidates[0] || {});
)JS");
    QString candidateCalls;
    for (const ScriptablePlayer &player : scriptablePlayers) {
        if (!candidateCalls.isEmpty()) {
            candidateCalls += QStringLiteral(", ");
        }
        candidateCalls += QStringLiteral("read('%1', %2)").arg(QString::fromLatin1(player.appName)).arg(player.durationMultiplier);
    }
    const QString encodedPreferredArray = QString::fromUtf8(QJsonDocument(QJsonArray{preferredSource}).toJson(QJsonDocument::Compact));
    const QString encodedPreferred = encodedPreferredArray.mid(1, encodedPreferredArray.size() - 2);
    return runAppleScript(script.arg(encodedPreferred).arg(candidateCalls), QStringLiteral("AppleScript"));
}

QByteArray readMusicArtworkFallback()
{
    static bool reportedFailure = false;
    QTemporaryFile file;
    if (!file.open()) {
        return {};
    }

    const QString path = file.fileName();
    file.close();

    QProcess process;
    process.setProgram(QStringLiteral("/usr/bin/osascript"));
    process.setArguments({QStringLiteral("-e"), QStringLiteral(R"AS(
on run argv
    set outputPath to item 1 of argv
    try
        tell application "Music"
            if it is not running then return
            set currentArtwork to artwork 1 of current track
            set artworkData to raw data of currentArtwork
            set outputFile to open for access POSIX file outputPath with write permission
            set eof of outputFile to 0
            write artworkData to outputFile
            close access outputFile
        end tell
    end try
end run
)AS"), path});
    process.start();
    if (!process.waitForFinished(appleScriptTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        if (!reportedFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Music artwork fallback failed" << process.exitCode()
                                                    << QString::fromUtf8(process.readAllStandardError()).trimmed();
            reportedFailure = true;
        }
        process.kill();
        process.waitForFinished(processCleanupTimeoutMs);
        return {};
    }

    if (!file.open() || file.size() <= 0 || file.size() > maxAlbumArtBytes) {
        if (!reportedFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Music artwork fallback empty or too large" << file.size();
            reportedFailure = true;
        }
        return {};
    }
    return file.readAll();
}

QByteArray readSpotifyArtworkFallback()
{
    static bool reportedFailure = false;
    static const QString script = QStringLiteral(R"JS(
try {
  const app = Application('Spotify');
  if (!app.running()) '';
  else String(app.currentTrack().artworkUrl ? app.currentTrack().artworkUrl() : '');
} catch (e) { ''; }
)JS");

    QProcess osascript;
    osascript.setProgram(QStringLiteral("/usr/bin/osascript"));
    osascript.setArguments({QStringLiteral("-l"), QStringLiteral("JavaScript"), QStringLiteral("-e"), script});
    osascript.start();
    if (!osascript.waitForFinished(appleScriptTimeoutMs) || osascript.exitStatus() != QProcess::NormalExit || osascript.exitCode() != 0) {
        if (!reportedFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Spotify artwork URL fallback failed" << osascript.exitCode()
                                                    << QString::fromUtf8(osascript.readAllStandardError()).trimmed();
            reportedFailure = true;
        }
        osascript.kill();
        osascript.waitForFinished(processCleanupTimeoutMs);
        return {};
    }

    const QString url = QString::fromUtf8(osascript.readAllStandardOutput()).trimmed();
    if (!url.startsWith(QLatin1String("https://i.scdn.co/image/"))) {
        return {};
    }

    QProcess curl;
    curl.setProgram(QStringLiteral("/usr/bin/curl"));
    curl.setArguments({QStringLiteral("--silent"),
                       QStringLiteral("--show-error"),
                       QStringLiteral("--location"),
                       QStringLiteral("--max-time"),
                       QStringLiteral("2"),
                       QStringLiteral("--max-filesize"),
                       QString::number(maxAlbumArtBytes),
                       url});
    curl.start();
    if (!curl.waitForFinished(2500) || curl.exitStatus() != QProcess::NormalExit || curl.exitCode() != 0) {
        if (!reportedFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Spotify artwork download failed" << curl.exitCode() << QString::fromUtf8(curl.readAllStandardError()).trimmed();
            reportedFailure = true;
        }
        curl.kill();
        curl.waitForFinished(processCleanupTimeoutMs);
        return {};
    }

    const QByteArray artwork = curl.readAllStandardOutput();
    if (artwork.isEmpty() || artwork.size() > maxAlbumArtBytes) {
        if (!reportedFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Spotify artwork download empty or too large" << artwork.size();
            reportedFailure = true;
        }
        return {};
    }
    return artwork;
}

QByteArray readAppleScriptArtworkFallback(const QString &source)
{
    for (const ScriptablePlayer &player : scriptablePlayers) {
        if (player.artworkReader && source.contains(QLatin1String(player.appName), Qt::CaseInsensitive)) {
            return player.artworkReader();
        }
    }
    return {};
}

NowPlayingInfo queryPlatformHelperFallback()
{
    NowPlayingInfo result;
    const QString program = qEnvironmentVariable("KDECONNECT_MACOS_MEDIAREMOTE_HELPER");
    if (program.isEmpty()) {
        return result;
    }

    QProcess process;
    process.setProgram(program);
    process.start();
    if (!process.waitForFinished(helperTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        process.waitForFinished(processCleanupTimeoutMs);
        return result;
    }

    const QJsonDocument document = QJsonDocument::fromJson(process.readAllStandardOutput().trimmed());
    if (!document.isObject()) {
        return result;
    }

    const QJsonObject object = document.object();
    result.title = object.value(keyTitle).toString();
    result.artist = object.value(keyArtist).toString();
    result.album = object.value(keyAlbum).toString();
    result.length = object.value(keyLength).toInteger(object.value(QStringLiteral("duration")).toDouble(-0.001) >= 0
                                                                  ? static_cast<qint64>(object.value(QStringLiteral("duration")).toDouble() * 1000.0)
                                                                  : -1);
    result.pos = object.value(keyPos).toInteger(object.value(QStringLiteral("elapsed")).toDouble(0.0) > 0
                                                            ? static_cast<qint64>(object.value(QStringLiteral("elapsed")).toDouble() * 1000.0)
                                                            : 0);
    result.hasPosition = object.contains(keyPos) || object.contains(QStringLiteral("elapsed"));
    result.hasPlaybackRate = object.contains(keyIsPlaying);
    result.playbackRate = object.value(keyPlaybackRate).toDouble(object.value(keyIsPlaying).toBool(false) ? 1.0 : 0.0);
    result.isPlaying = object.value(keyIsPlaying).toBool(false);
    result.hasDescriptiveMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.hasPosition;
    result.hasUsefulMetadata = result.hasDescriptiveMetadata || result.hasPlaybackRate;
    if (!result.hasDescriptiveMetadata && result.hasPlaybackRate && result.isPlaying) {
        result.title = nowPlayingPlayer();
    }
    if (result.hasUsefulMetadata) {
        result.source = QStringLiteral("platform-helper");
    }
    return result;
}

// Locates the external media-control helper (https://github.com/ungive/media-control), which reads
// and controls now-playing media on macOS 15.4+ where direct MediaRemote access is gated for
// third-party processes. Returns an empty string when unavailable.
QString mediaControlProgramFromEnvironment()
{
    const QString overridePath = qEnvironmentVariable("KDECONNECT_MACOS_MEDIA_CONTROL");
    if (!overridePath.isEmpty()) {
        return QFileInfo::exists(overridePath) ? overridePath : QString();
    }
    QString program = QStandardPaths::findExecutable(QStringLiteral("media-control"));
    if (program.isEmpty()) {
        const QStringList fallbackLocations = {QStringLiteral("/opt/homebrew/bin/media-control"), QStringLiteral("/usr/local/bin/media-control")};
        for (const QString &location : fallbackLocations) {
            if (QFileInfo::exists(location)) {
                program = location;
                break;
            }
        }
    }
    return program;
}

// A human readable name for the app that currently owns now playing.
QString applicationDisplayName(const QString &bundleIdentifier, qint64 processIdentifier)
{
    if (processIdentifier > 0) {
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(processIdentifier)];
        NSString *name = application.localizedName;
        if (name.length > 0) {
            return QString::fromNSString(name);
        }
    }
    const QString fallback = bundleIdentifier.section(QLatin1Char('.'), -1);
    return fallback.isEmpty() ? QStringLiteral("Now Playing") : fallback;
}

// Parses the JSON emitted by "media-control get". Times are seconds, positions map to
// NowPlayingInfo milliseconds.
void parseMediaControlObject(const QJsonObject &object, NowPlayingInfo &result)
{
    result.title = object.value(keyTitle).toString();
    result.artist = object.value(keyArtist).toString();
    result.album = object.value(keyAlbum).toString();

    const double duration = object.value(QStringLiteral("duration")).toDouble(-1);
    if (duration >= 0) {
        result.length = secondsToMilliseconds(duration, -1);
    }
    if (object.contains(QStringLiteral("elapsedTime"))) {
        result.pos = secondsToMilliseconds(object.value(QStringLiteral("elapsedTime")).toDouble(0.0));
        result.hasPosition = true;
    }

    result.isPlaying = object.value(QStringLiteral("playing")).toBool(false);
    result.hasPlaybackRate = true;
    result.playbackRate = object.value(keyPlaybackRate).toDouble(result.isPlaying ? 1.0 : 0.0);

    result.bundleIdentifier = object.value(QStringLiteral("bundleIdentifier")).toString();
    result.contentItemIdentifier = object.value(QStringLiteral("contentItemIdentifier")).toString();
    result.processIdentifier = static_cast<qint64>(object.value(QStringLiteral("processIdentifier")).toDouble(0.0));

    result.hasDescriptiveMetadata =
        !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.hasPosition;
    result.hasUsefulMetadata = result.hasDescriptiveMetadata || result.hasPlaybackRate;
    if (result.hasUsefulMetadata) {
        result.source = QStringLiteral("media-control");
    }
}

NowPlayingInfo fallbackNowPlayingInfo(bool hasLastKnownIsPlaying, bool lastKnownIsPlaying)
{
    NowPlayingInfo result;
    result.title = QStringLiteral("Now Playing");
    result.hasPlaybackRate = true;
    result.isPlaying = hasLastKnownIsPlaying ? lastKnownIsPlaying : false;
    result.playbackRate = result.isPlaying ? 1.0 : 0.0;
    result.hasUsefulMetadata = true;
    result.hasDescriptiveMetadata = true;
    result.source = QStringLiteral("safe-default");
    return result;
}

NowPlayingInfo queryMediaRemotePlaybackStateFallback()
{
    bool ok = false;
    const bool isPlaying = MediaRemote::self().queryIsPlaying(&ok);
    if (!ok || !isPlaying) {
        return {};
    }

    return fallbackNowPlayingInfo(true, true);
}

NowPlayingInfo queryGenericFallback()
{
    NowPlayingInfo genericFallback = queryMediaRemotePlaybackStateFallback();
    if (!genericFallback.hasUsefulMetadata) {
        genericFallback = queryPlatformHelperFallback();
    }
    return genericFallback;
}

}

MprisControlPlugin::MprisControlPlugin(QObject *parent, const QVariantList &args)
    : KdeConnectPlugin(parent, args)
{
    @autoreleasepool {
        MediaRemote::self();
    }

    m_mediaControlProgram = mediaControlProgramFromEnvironment();
    if (!m_mediaControlProgram.isEmpty()) {
        QProcess process;
        process.setProgram(m_mediaControlProgram);
        process.setArguments({QStringLiteral("test")});
        process.start();
        if (!process.waitForFinished(mediaControlGetTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
            process.kill();
            process.waitForFinished(processCleanupTimeoutMs);
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "media-control helper found but not functional on this system; using direct MediaRemote access";
            m_mediaControlProgram.clear();
        }
    }

    sendPlayerList();
    sendNowPlaying(true);

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(pollIntervalMs);
    connect(m_pollTimer, &QTimer::timeout, this, &MprisControlPlugin::pollNowPlaying);
    m_pollTimer->start();
    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Polling macOS now-playing metadata every" << pollIntervalMs << "ms";
}

void MprisControlPlugin::receivePacket(const NetworkPacket &np)
{
    if (np.has(QStringLiteral("playerList"))) {
        return;
    }

    const QString player = np.get<QString>(keyPlayer);
    // Accept the previous player name as well: the remote may still address the old
    // entry until it processes the updated player list.
    const bool knownPlayer =
        player.isEmpty() || player == currentPlayerName() || player == m_previousPlayerName || player == QLatin1String("Now Playing");

    if (np.get<bool>(QStringLiteral("requestPlayerList"))) {
        sendPlayerList();
        if (!knownPlayer) {
            return;
        }
    }

    if (!knownPlayer) {
        return;
    }

    if (np.has(keyAlbumArtUrl)) {
        sendAlbumArt(np.get<QString>(keyAlbumArtUrl));
        return;
    }

    bool handledAction = false;
    if (np.has(QStringLiteral("action"))) {
        handledAction = handleAction(np.get<QString>(QStringLiteral("action")));
    }

    // Seek is delivered through the media-control helper; direct MediaRemote has a private
    // SeekToPlaybackPosition command, but this backend has no locally verified, safe argument
    // dictionary contract for it.
    const bool handledSeek = handleSeekPacket(np);
    if (handledSeek && !handledAction) {
        sendNowPlaying();
    }

    if (handledAction) {
        sendNowPlaying();
    } else if (np.get<bool>(QStringLiteral("requestNowPlaying"))) {
        sendPlayerList();
        sendNowPlaying(true);
    }
}

bool MprisControlPlugin::handleAction(const QString &action)
{
    // Commands prefer the external media-control helper (works on macOS 15.4+ where direct
    // MediaRemote command delivery is gated); direct MediaRemote remains as fallback.
    auto sendCommand = [this](const char *helperCommand, int mediaRemoteCommand) {
        if (!m_mediaControlProgram.isEmpty() && sendMediaControlCommand(QStringList{QString::fromLatin1(helperCommand)})) {
            return true;
        }
        const bool sent = MediaRemote::self().sendCommand(mediaRemoteCommand);
        if (!sent && !m_reportedCommandUnavailable) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Ignoring media command: MediaRemote command symbol unavailable";
            m_reportedCommandUnavailable = true;
        }
        return sent;
    };

    auto freezeProgress = [this]() {
        QVariantMap body = defaultNowPlayingBody();
        estimatePlaybackProgress(body);
        m_lastPosition = body.value(keyPos).toLongLong();
        m_lastPositionSampleTime = QDateTime::currentMSecsSinceEpoch();
    };

    if (action == QStringLiteral("Play")) {
        sendCommand("play", commandPlay);
        m_lastKnownIsPlaying = true;
        m_hasLastKnownIsPlaying = true;
        m_lastPlaybackRate = 1.0;
        if (m_hasLastPosition) {
            m_lastPositionSampleTime = QDateTime::currentMSecsSinceEpoch();
        }
        return true;
    }

    if (action == QStringLiteral("Pause") || action == QStringLiteral("Stop")) {
        freezeProgress();
        sendCommand("pause", commandPause);
        m_lastKnownIsPlaying = false;
        m_hasLastKnownIsPlaying = true;
        m_lastPlaybackRate = 0.0;
        return true;
    }

    if (action == QStringLiteral("PlayPause")) {
        freezeProgress();
        sendCommand("toggle-play-pause", commandTogglePlayPause);
        m_lastKnownIsPlaying = m_hasLastKnownIsPlaying ? !m_lastKnownIsPlaying : true;
        m_hasLastKnownIsPlaying = true;
        m_lastPlaybackRate = m_lastKnownIsPlaying ? 1.0 : 0.0;
        return true;
    }

    if (action == QStringLiteral("Next")) {
        sendCommand("next-track", commandNextTrack);
        m_hasLastPosition = false;
        return true;
    }

    if (action == QStringLiteral("Previous")) {
        sendCommand("previous-track", commandPreviousTrack);
        m_hasLastPosition = false;
        return true;
    }

    return false;
}

QString MprisControlPlugin::currentPlayerName() const
{
    return m_activePlayerName.isEmpty() ? QStringLiteral("Now Playing") : m_activePlayerName;
}

bool MprisControlPlugin::sendMediaControlCommand(const QStringList &arguments)
{
    if (m_mediaControlProgram.isEmpty()) {
        return false;
    }

    QProcess process;
    process.setProgram(m_mediaControlProgram);
    process.setArguments(arguments);
    process.start();
    if (!process.waitForFinished(mediaControlCommandTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        process.waitForFinished(processCleanupTimeoutMs);
        if (!m_reportedMediaControlFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "media-control helper command failed:" << arguments;
            m_reportedMediaControlFailure = true;
        }
        return false;
    }
    return true;
}

bool MprisControlPlugin::handleSeekPacket(const NetworkPacket &np)
{
    const bool hasSetPosition = np.has(QStringLiteral("SetPosition"));
    const bool hasSeek = np.has(QStringLiteral("Seek"));
    if (!hasSetPosition && !hasSeek) {
        return false;
    }

    if (m_mediaControlProgram.isEmpty()) {
        if (!m_reportedSeekUnsupported) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Ignoring seek request: no verified seek implementation available";
            m_reportedSeekUnsupported = true;
        }
        return false;
    }

    qlonglong targetMs = 0;
    if (hasSetPosition) {
        targetMs = np.get<qlonglong>(QStringLiteral("SetPosition"), 0);
    } else {
        QVariantMap body = defaultNowPlayingBody();
        estimatePlaybackProgress(body);
        targetMs = body.value(keyPos).toLongLong() + np.get<qlonglong>(QStringLiteral("Seek"), 0);
    }
    targetMs = std::max<qlonglong>(0, targetMs);
    const qlonglong length = m_lastNowPlayingBody.value(keyLength, -1).toLongLong();
    if (length >= 0) {
        targetMs = std::min(targetMs, length);
    }

    if (!sendMediaControlCommand({QStringLiteral("seek"), QString::number(targetMs / 1000.0, 'f', 3)})) {
        if (!m_reportedSeekUnsupported) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Ignoring seek request: media-control seek failed";
            m_reportedSeekUnsupported = true;
        }
        return false;
    }

    m_lastPosition = targetMs;
    m_lastPositionSampleTime = QDateTime::currentMSecsSinceEpoch();
    m_hasLastPosition = true;
    return true;
}

void MprisControlPlugin::updateActivePlayer(const NowPlayingInfo &nowPlaying)
{
    if (nowPlaying.bundleIdentifier.isEmpty() || nowPlaying.bundleIdentifier == m_activeAppBundleIdentifier) {
        return;
    }

    m_activeAppBundleIdentifier = nowPlaying.bundleIdentifier;
    const QString previousName = currentPlayerName();
    m_activePlayerName = applicationDisplayName(nowPlaying.bundleIdentifier, nowPlaying.processIdentifier);
    m_previousPlayerName = previousName;
    m_lastSupportedSource.clear();
    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Active player is now" << m_activePlayerName << nowPlaying.bundleIdentifier;

    // Re-announce the player list so the remote replaces the old entry. Without this the
    // remote ignores now-playing updates for the renamed player and keeps addressing
    // commands to the stale name.
    sendPlayerList();
}

NowPlayingInfo MprisControlPlugin::queryMediaControl()
{
    NowPlayingInfo result;
    if (m_mediaControlProgram.isEmpty()) {
        return result;
    }

    QProcess process;
    process.setProgram(m_mediaControlProgram);
    process.setArguments({QStringLiteral("get"), QStringLiteral("--no-artwork")});
    process.start();
    if (!process.waitForFinished(mediaControlGetTimeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        process.waitForFinished(processCleanupTimeoutMs);
        if (!m_reportedMediaControlFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "media-control metadata query failed";
            m_reportedMediaControlFailure = true;
        }
        return result;
    }

    const QJsonDocument document = QJsonDocument::fromJson(process.readAllStandardOutput().trimmed());
    if (!document.isObject()) {
        if (!m_reportedMediaControlFailure) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "media-control metadata query returned no JSON object";
            m_reportedMediaControlFailure = true;
        }
        return result;
    }
    parseMediaControlObject(document.object(), result);
    if (!result.hasUsefulMetadata) {
        return result;
    }

    updateActivePlayer(result);

    // Artwork is heavy; fetch it only when the playing item changed and keep the cached bytes otherwise.
    if (m_mediaControlArtworkValid && result.contentItemIdentifier == m_mediaControlArtworkItemId) {
        result.artworkBytes = m_albumArtBytes;
        return result;
    }

    NowPlayingInfo artworkInfo;
    QProcess artworkProcess;
    artworkProcess.setProgram(m_mediaControlProgram);
    artworkProcess.setArguments({QStringLiteral("get")});
    artworkProcess.start();
    if (artworkProcess.waitForFinished(mediaControlArtworkTimeoutMs) && artworkProcess.exitStatus() == QProcess::NormalExit
        && artworkProcess.exitCode() == 0) {
        const QJsonDocument artworkDocument = QJsonDocument::fromJson(artworkProcess.readAllStandardOutput().trimmed());
        if (artworkDocument.isObject()) {
            parseMediaControlObject(artworkDocument.object(), artworkInfo);
            const QByteArray artwork = QByteArray::fromBase64(artworkDocument.object().value(QStringLiteral("artworkData")).toString().toLatin1());
            if (!artwork.isEmpty() && artwork.size() <= maxAlbumArtBytes) {
                result.artworkBytes = artwork;
            }
        }
    } else {
        artworkProcess.kill();
        artworkProcess.waitForFinished(processCleanupTimeoutMs);
    }

    m_mediaControlArtworkItemId = result.contentItemIdentifier;
    m_mediaControlArtworkValid = true;
    return result;
}

void MprisControlPlugin::sendPlayerList()
{
    NetworkPacket np(PACKET_TYPE_MPRIS);
    np.set(QStringLiteral("playerList"), QStringList{currentPlayerName()});
    np.set(QStringLiteral("supportAlbumArtPayload"), true);
    sendPacket(np);
}

bool MprisControlPlugin::sendAlbumArt(const QString &requestedAlbumArtUrl)
{
    if (requestedAlbumArtUrl.isEmpty() || requestedAlbumArtUrl != m_albumArtUrl || m_albumArtBytes.isEmpty() || m_albumArtBytes.size() > maxAlbumArtBytes) {
        qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Ignoring album art request" << requestedAlbumArtUrl << "current" << m_albumArtUrl << "bytes"
                                               << m_albumArtBytes.size();
        return false;
    }

    auto buffer = QSharedPointer<QBuffer>::create();
    buffer->setData(m_albumArtBytes);
    if (!buffer->open(QIODevice::ReadOnly)) {
        return false;
    }

    NetworkPacket answer(PACKET_TYPE_MPRIS);
    answer.set(QStringLiteral("transferringAlbumArt"), true);
    answer.set(keyPlayer, currentPlayerName());
    answer.set(keyAlbumArtUrl, requestedAlbumArtUrl);
    answer.setPayload(buffer, buffer->size());
    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Sending album art payload" << requestedAlbumArtUrl << buffer->size();
    sendPacket(answer);
    return true;
}

void MprisControlPlugin::sendNowPlaying(bool force)
{
    requestNowPlaying(force);
}

void MprisControlPlugin::pollNowPlaying()
{
    requestNowPlaying(false);
}

QVariantMap MprisControlPlugin::defaultNowPlayingBody() const
{
    QVariantMap body;
    body[keyPlayer] = currentPlayerName();
    body[QStringLiteral("title")] = QString();
    body[QStringLiteral("artist")] = QString();
    body[QStringLiteral("album")] = QString();
    body[keyAlbumArtUrl] = QString();
    body[QStringLiteral("url")] = QUrl();
    body[keyLength] = -1;
    body[keyPos] = 0;
    body[keyIsPlaying] = m_hasLastKnownIsPlaying ? m_lastKnownIsPlaying : false;
    const bool canControl = !m_mediaControlProgram.isEmpty() || MediaRemote::self().canSendCommands();
    body[QStringLiteral("canPause")] = canControl;
    body[QStringLiteral("canPlay")] = canControl;
    body[QStringLiteral("canGoNext")] = canControl;
    body[QStringLiteral("canGoPrevious")] = canControl;
    body[QStringLiteral("canSeek")] = !m_mediaControlProgram.isEmpty();
    return body;
}

void MprisControlPlugin::rememberSupportedSource(const NowPlayingInfo &nowPlaying)
{
    if (nowPlaying.source.startsWith(QLatin1String("AppleScript/")) && nowPlaying.hasPlaybackRate && nowPlaying.isPlaying) {
        m_lastSupportedSource = nowPlaying.source;
    }
}

NowPlayingInfo MprisControlPlugin::selectFallbackNowPlaying(const NowPlayingInfo &supportedApp, const NowPlayingInfo &genericFallback) const
{
    if (supportedApp.hasUsefulMetadata && supportedApp.hasPlaybackRate && supportedApp.isPlaying) {
        return supportedApp;
    }

    if (genericFallback.hasUsefulMetadata && genericFallback.hasPlaybackRate && genericFallback.isPlaying) {
        return genericFallback;
    }

    if (supportedApp.hasUsefulMetadata) {
        if (m_lastSupportedSource.isEmpty() || supportedApp.source == m_lastSupportedSource) {
            return supportedApp;
        }
    }

    if (genericFallback.hasUsefulMetadata) {
        return genericFallback;
    }

    return fallbackNowPlayingInfo(m_hasLastKnownIsPlaying, m_lastKnownIsPlaying);
}

void MprisControlPlugin::applyNowPlayingInfo(QVariantMap &body, const NowPlayingInfo &nowPlaying, qint64 sampleTime)
{
    rememberSupportedSource(nowPlaying);
    updateAlbumArt(nowPlaying.artworkBytes.isEmpty() ? readAppleScriptArtworkFallback(nowPlaying.source) : nowPlaying.artworkBytes);
    body[keyTitle] = nowPlaying.title;
    body[keyArtist] = nowPlaying.artist;
    body[keyAlbum] = nowPlaying.album;
    body[keyLength] = nowPlaying.length;
    body[keyPos] = nowPlaying.pos;
    updatePlaybackProgress(nowPlaying.hasPosition, nowPlaying.pos, nowPlaying.hasPlaybackRate, nowPlaying.playbackRate, sampleTime);
    if (nowPlaying.hasPlaybackRate) {
        m_lastKnownIsPlaying = nowPlaying.isPlaying;
        m_hasLastKnownIsPlaying = true;
        body[keyIsPlaying] = nowPlaying.isPlaying;
    }
}

void MprisControlPlugin::updateAlbumArt(const QByteArray &artworkBytes)
{
    if (artworkBytes.isEmpty() || artworkBytes.size() > maxAlbumArtBytes) {
        if (!m_albumArtBytes.isEmpty()) {
            m_albumArtBytes.clear();
            m_albumArtHash.clear();
            m_albumArtUrl.clear();
            ++m_albumArtRevision;
        }
        return;
    }

    const QByteArray hash = QCryptographicHash::hash(artworkBytes, QCryptographicHash::Sha256).toHex();
    if (hash == m_albumArtHash) {
        return;
    }

    m_albumArtBytes = artworkBytes;
    m_albumArtHash = hash;
    m_albumArtUrl = QStringLiteral("kdeconnect://macos-nowplaying/art/%1/%2").arg(++m_albumArtRevision).arg(QString::fromLatin1(hash.left(16)));
    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Cached album art" << m_albumArtUrl << m_albumArtBytes.size();
}

void MprisControlPlugin::updatePlaybackProgress(bool hasPosition, qlonglong position, bool hasPlaybackRate, double playbackRate, qint64 sampleTime)
{
    const double previousPlaybackRate = m_lastPlaybackRate;
    if (hasPlaybackRate) {
        m_lastPlaybackRate = playbackRate;
    }
    if (!hasPosition) {
        return;
    }

    if (hasPlaybackRate && playbackRate > minimumPlayingRate && previousPlaybackRate > minimumPlayingRate && m_hasLastPosition && position <= m_lastPosition
        && position + 1000 >= m_lastPosition) {
        const qint64 elapsed = sampleTime - m_lastPositionSampleTime;
        if (elapsed > 0) {
            position = m_lastPosition + static_cast<qlonglong>(elapsed * previousPlaybackRate);
        }
    }

    m_lastPosition = position;
    m_lastPositionSampleTime = sampleTime;
    m_hasLastPosition = true;
}

void MprisControlPlugin::estimatePlaybackProgress(QVariantMap &body) const
{
    if (!m_hasLastPosition) {
        return;
    }

    qlonglong position = m_lastPosition;
    if (m_lastPlaybackRate > minimumPlayingRate) {
        const qint64 elapsed = QDateTime::currentMSecsSinceEpoch() - m_lastPositionSampleTime;
        if (elapsed > 0) {
            position += static_cast<qlonglong>(elapsed * m_lastPlaybackRate);
        }
    }

    const qlonglong length = body.value(keyLength, -1).toLongLong();
    if (length >= 0) {
        position = std::min(position, length);
    }
    body[keyPos] = std::max<qlonglong>(0, position);
}

void MprisControlPlugin::requestNowPlaying(bool force)
{
    // Prefer the media-control helper tier: it is the only source that works on macOS 15.4+
    // where direct MediaRemote reads are gated for third-party processes.
    if (!m_mediaControlProgram.isEmpty()) {
        const NowPlayingInfo nowPlaying = queryMediaControl();
        if (nowPlaying.hasUsefulMetadata) {
            const qint64 sampleTime = QDateTime::currentMSecsSinceEpoch();
            QVariantMap body = defaultNowPlayingBody();
            applyNowPlayingInfo(body, nowPlaying, sampleTime);
            if (!m_reportedNowPlayingInfo && nowPlaying.source != QStringLiteral("safe-default")) {
                qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Now-playing metadata available from" << nowPlaying.source;
                m_reportedNowPlayingInfo = true;
            }
            sendNowPlayingBody(body, force);
            return;
        }
    }

    if (m_nowPlayingRequestInFlight) {
        m_forceSendAfterNowPlayingReply = m_forceSendAfterNowPlayingReply || force;
        return;
    }

    if (!MediaRemote::self().canReadNowPlayingInfo()) {
        const NowPlayingInfo nowPlaying = selectFallbackNowPlaying(queryAppleScriptFallbacks(m_lastSupportedSource), queryGenericFallback());
        const qint64 sampleTime = QDateTime::currentMSecsSinceEpoch();
        QVariantMap body = defaultNowPlayingBody();
        applyNowPlayingInfo(body, nowPlaying, sampleTime);
        sendNowPlayingBody(body, force);
        return;
    }

    m_nowPlayingRequestInFlight = true;
    m_forceSendAfterNowPlayingReply = force;
    const int requestId = ++m_nowPlayingRequestId;
    QPointer<MprisControlPlugin> guard(this);
    QTimer::singleShot(nowPlayingTimeoutMs, this, [this, requestId]() {
        if (!m_nowPlayingRequestInFlight || requestId != m_nowPlayingRequestId) {
            return;
        }
        m_nowPlayingRequestInFlight = false;
        const bool forceSend = m_forceSendAfterNowPlayingReply;
        m_forceSendAfterNowPlayingReply = false;
        if (!m_reportedNowPlayingTimeout) {
            qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "MediaRemote now-playing metadata request timed out";
            m_reportedNowPlayingTimeout = true;
        }
        const NowPlayingInfo fallback = selectFallbackNowPlaying(queryAppleScriptFallbacks(m_lastSupportedSource), queryGenericFallback());
        QVariantMap body = defaultNowPlayingBody();
        applyNowPlayingInfo(body, fallback, QDateTime::currentMSecsSinceEpoch());
        sendNowPlayingBody(body, forceSend);
    });

    MediaRemote::self().getNowPlayingInfoAsync(^(CFDictionaryRef info) {
        if (!guard) {
            return;
        }

        NowPlayingInfo nowPlaying;
        const qint64 sampleTime = QDateTime::currentMSecsSinceEpoch();
        @autoreleasepool {
            nowPlaying = readNowPlayingInfo(info);
        }
        if (!nowPlaying.hasUsefulMetadata) {
            QMetaObject::invokeMethod(guard.data(), [guard, requestId, sampleTime]() {
                if (!guard) {
                    return;
                }
                if (!guard->m_nowPlayingRequestInFlight || requestId != guard->m_nowPlayingRequestId) {
                    return;
                }
                const NowPlayingInfo fallback = guard->selectFallbackNowPlaying(queryAppleScriptFallbacks(guard->m_lastSupportedSource), queryGenericFallback());
                guard->m_nowPlayingRequestInFlight = false;
                const bool forceSend = guard->m_forceSendAfterNowPlayingReply;
                guard->m_forceSendAfterNowPlayingReply = false;
                QVariantMap body = guard->defaultNowPlayingBody();
                guard->applyNowPlayingInfo(body, fallback, sampleTime);
                guard->sendNowPlayingBody(body, forceSend);
            }, Qt::QueuedConnection);
            return;
        }

        QMetaObject::invokeMethod(guard.data(), [guard, requestId, nowPlaying, sampleTime]() {
            if (!guard) {
                return;
            }
            if (!guard->m_nowPlayingRequestInFlight || requestId != guard->m_nowPlayingRequestId) {
                return;
            }

            guard->m_nowPlayingRequestInFlight = false;
            const bool forceSend = guard->m_forceSendAfterNowPlayingReply;
            guard->m_forceSendAfterNowPlayingReply = false;

            QVariantMap body = guard->defaultNowPlayingBody();
            guard->applyNowPlayingInfo(body, nowPlaying, sampleTime);
            if (!guard->m_reportedNowPlayingInfo && nowPlaying.source != QStringLiteral("safe-default")) {
                qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Now-playing metadata available from" << nowPlaying.source;
                guard->m_reportedNowPlayingInfo = true;
            }

            guard->sendNowPlayingBody(body, forceSend);
        }, Qt::QueuedConnection);
    });
}

void MprisControlPlugin::sendNowPlayingBody(QVariantMap body, bool force)
{
    body[keyAlbumArtUrl] = m_albumArtUrl;
    body[QStringLiteral("supportAlbumArtPayload")] = true;
    estimatePlaybackProgress(body);
    if (!force && m_hasLastNowPlayingBody && body == m_lastNowPlayingBody) {
        return;
    }

    NetworkPacket np(PACKET_TYPE_MPRIS, body);
    sendPacket(np);
    m_lastNowPlayingBody = body;
    m_hasLastNowPlayingBody = true;
}

#include "moc_mpriscontrolplugin-macos.cpp"
#include "mpriscontrolplugin-macos.moc"