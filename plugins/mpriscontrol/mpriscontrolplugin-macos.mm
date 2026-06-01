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
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>

#include <cmath>
#include <dlfcn.h>
#include <memory>

#import <Foundation/Foundation.h>

K_PLUGIN_CLASS_WITH_JSON(MprisControlPlugin, "kdeconnect_mpriscontrol.json")

namespace
{
const QString nowPlayingPlayer()
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

qlonglong secondsToMilliseconds(double seconds, qlonglong fallback = 0)
{
    if (!std::isfinite(seconds) || seconds < 0) {
        return fallback;
    }
    return static_cast<qlonglong>(seconds * 1000.0);
}

struct NowPlayingInfo {
    QString title;
    QString artist;
    QString album;
    qlonglong length = -1;
    qlonglong pos = 0;
    bool hasPlaybackRate = false;
    bool isPlaying = false;
    bool hasUsefulMetadata = false;
    QString source;
};

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

        struct State {
            Boolean playing = false;
            bool answered = false;
        };

        auto state = std::make_shared<State>();
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        m_getIsPlaying(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(Boolean isPlaying) {
            state->playing = isPlaying;
            state->answered = true;
            dispatch_semaphore_signal(semaphore);
        });

        const long timeout = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        if (timeout != 0 || !state->answered) {
            return false;
        }

        *ok = true;
        return state->playing;
    }

    CFStringRef keyTitle() const { return key(m_keyTitle); }
    CFStringRef keyArtist() const { return key(m_keyArtist); }
    CFStringRef keyAlbum() const { return key(m_keyAlbum); }
    CFStringRef keyDuration() const { return key(m_keyDuration); }
    CFStringRef keyElapsedTime() const { return key(m_keyElapsedTime); }
    CFStringRef keyPlaybackRate() const { return key(m_keyPlaybackRate); }

private:
    MediaRemote()
    {
        if (qEnvironmentVariableIsSet("KDECONNECT_DISABLE_MACOS_MEDIAREMOTE")) {
            qCInfo(KDECONNECT_PLUGIN_MPRISCONTROL) << "macOS MediaRemote disabled by KDECONNECT_DISABLE_MACOS_MEDIAREMOTE";
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
    }
    if (cfNumberToDouble(value(MediaRemote::self().keyPlaybackRate()), &number)) {
        result.hasPlaybackRate = true;
        result.isPlaying = number > 0.01;
    }

    result.hasUsefulMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.pos > 0
        || result.hasPlaybackRate;
    if (result.hasUsefulMetadata) {
        result.source = QStringLiteral("MediaRemote");
    }
    return result;
}

void mergeNowPlaying(NowPlayingInfo &target, const NowPlayingInfo &fallback)
{
    if (!fallback.hasUsefulMetadata) {
        return;
    }
    if (target.hasUsefulMetadata) {
        if (target.hasPlaybackRate && !target.isPlaying && fallback.hasPlaybackRate && fallback.isPlaying) {
            target = fallback;
        }
        return;
    }
    target = fallback;
}

NowPlayingInfo runAppleScript(const QString &script, const QString &source)
{
    NowPlayingInfo result;
    QProcess process;
    process.setProgram(QStringLiteral("/usr/bin/osascript"));
    process.setArguments({QStringLiteral("-l"), QStringLiteral("JavaScript"), QStringLiteral("-e"), script});
    process.start();
    if (!process.waitForFinished(900) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        process.waitForFinished(100);
        return result;
    }

    const QJsonDocument document = QJsonDocument::fromJson(process.readAllStandardOutput().trimmed());
    if (!document.isObject()) {
        return result;
    }

    const QJsonObject object = document.object();
    result.title = object.value(QStringLiteral("title")).toString();
    result.artist = object.value(QStringLiteral("artist")).toString();
    result.album = object.value(QStringLiteral("album")).toString();
    result.length = object.value(QStringLiteral("length")).toInteger(-1);
    result.pos = object.value(QStringLiteral("pos")).toInteger(0);
    result.hasPlaybackRate = object.contains(QStringLiteral("isPlaying"));
    result.isPlaying = object.value(QStringLiteral("isPlaying")).toBool(false);
    result.hasUsefulMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.pos > 0
        || result.hasPlaybackRate;
    if (result.hasUsefulMetadata) {
        result.source = object.value(QStringLiteral("source")).toString(source);
    }
    return result;
}

NowPlayingInfo queryAppleScriptFallbacks()
{
    static const QString script = QStringLiteral(R"JS(
function read(appName, durationMultiplier) {
  try {
    const app = Application(appName);
    app.includeStandardAdditions = true;
    if (!app.running()) return null;
    const state = String(app.playerState ? app.playerState() : '');
    const track = app.currentTrack();
    const duration = Number(track.duration ? track.duration() : 0);
    const position = Number(app.playerPosition ? app.playerPosition() : 0);
    const item = {
      title: String(track.name ? track.name() : ''),
      artist: String(track.artist ? track.artist() : ''),
      album: String(track.album ? track.album() : ''),
      length: isFinite(duration) && duration > 0 ? Math.round(duration * durationMultiplier) : -1,
      pos: isFinite(position) && position > 0 ? Math.round(position * 1000) : 0,
      isPlaying: state.toLowerCase() === 'playing',
      source: 'AppleScript/' + appName
    };
    if (!item.title && !item.artist && !item.album && item.length < 0 && item.pos <= 0) return null;
    return item;
  } catch (e) { return null; }
}
const candidates = [read('Music', 1000), read('Spotify', 1)].filter(Boolean);
JSON.stringify(candidates.find(x => x.isPlaying) || candidates[0] || {});
)JS");
    return runAppleScript(script, QStringLiteral("AppleScript"));
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
    if (!process.waitForFinished(500) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        process.kill();
        return result;
    }

    const QJsonDocument document = QJsonDocument::fromJson(process.readAllStandardOutput().trimmed());
    if (!document.isObject()) {
        return result;
    }

    const QJsonObject object = document.object();
    result.title = object.value(QStringLiteral("title")).toString();
    result.artist = object.value(QStringLiteral("artist")).toString();
    result.album = object.value(QStringLiteral("album")).toString();
    result.length = object.value(QStringLiteral("length")).toInteger(object.value(QStringLiteral("duration")).toDouble(-0.001) >= 0
                                                                  ? static_cast<qint64>(object.value(QStringLiteral("duration")).toDouble() * 1000.0)
                                                                  : -1);
    result.pos = object.value(QStringLiteral("pos")).toInteger(object.value(QStringLiteral("elapsed")).toDouble(0.0) > 0
                                                            ? static_cast<qint64>(object.value(QStringLiteral("elapsed")).toDouble() * 1000.0)
                                                            : 0);
    result.hasPlaybackRate = object.contains(QStringLiteral("isPlaying"));
    result.isPlaying = object.value(QStringLiteral("isPlaying")).toBool(false);
    result.hasUsefulMetadata = !result.title.isEmpty() || !result.artist.isEmpty() || !result.album.isEmpty() || result.length >= 0 || result.pos > 0
        || result.hasPlaybackRate;
    if (result.hasUsefulMetadata) {
        result.source = QStringLiteral("platform-helper");
    }
    return result;
}

NowPlayingInfo fallbackNowPlayingInfo(bool hasLastKnownIsPlaying, bool lastKnownIsPlaying)
{
    NowPlayingInfo result;
    result.title = QStringLiteral("Now Playing");
    result.hasPlaybackRate = true;
    result.isPlaying = hasLastKnownIsPlaying ? lastKnownIsPlaying : false;
    result.hasUsefulMetadata = true;
    result.source = QStringLiteral("safe-default");
    return result;
}

NowPlayingInfo queryFallbackCascade(bool hasLastKnownIsPlaying, bool lastKnownIsPlaying)
{
    NowPlayingInfo nowPlaying = queryAppleScriptFallbacks();
    if (!nowPlaying.hasUsefulMetadata) {
        mergeNowPlaying(nowPlaying, queryPlatformHelperFallback());
    }
    if (!nowPlaying.hasUsefulMetadata) {
        mergeNowPlaying(nowPlaying, fallbackNowPlayingInfo(hasLastKnownIsPlaying, lastKnownIsPlaying));
    }
    return nowPlaying;
}
}

MprisControlPlugin::MprisControlPlugin(QObject *parent, const QVariantList &args)
    : KdeConnectPlugin(parent, args)
{
    @autoreleasepool {
        MediaRemote::self();
    }
    sendPlayerList();
    sendNowPlaying(true);

    if (!MediaRemote::self().canReadNowPlayingInfo()) {
        return;
    }

    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(pollIntervalMs);
    connect(m_pollTimer, &QTimer::timeout, this, &MprisControlPlugin::pollNowPlaying);
    m_pollTimer->start();
    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Polling MediaRemote now-playing metadata every" << pollIntervalMs << "ms";
}

void MprisControlPlugin::receivePacket(const NetworkPacket &np)
{
    if (np.has(QStringLiteral("playerList"))) {
        return;
    }

    const QString player = np.get<QString>(QStringLiteral("player"));
    const bool knownPlayer = player.isEmpty() || player == nowPlayingPlayer();

    if (np.get<bool>(QStringLiteral("requestPlayerList"))) {
        sendPlayerList();
        if (!knownPlayer) {
            return;
        }
    }

    if (!knownPlayer) {
        return;
    }

    bool handledAction = false;
    if (np.has(QStringLiteral("action"))) {
        const QString action = np.get<QString>(QStringLiteral("action"));
        if (action == QStringLiteral("Play")) {
            MediaRemote::self().sendCommand(commandPlay);
            m_lastKnownIsPlaying = true;
            m_hasLastKnownIsPlaying = true;
            handledAction = true;
        } else if (action == QStringLiteral("Pause") || action == QStringLiteral("Stop")) {
            MediaRemote::self().sendCommand(commandPause);
            m_lastKnownIsPlaying = false;
            m_hasLastKnownIsPlaying = true;
            handledAction = true;
        } else if (action == QStringLiteral("PlayPause")) {
            MediaRemote::self().sendCommand(commandTogglePlayPause);
            m_lastKnownIsPlaying = m_hasLastKnownIsPlaying ? !m_lastKnownIsPlaying : true;
            m_hasLastKnownIsPlaying = true;
            handledAction = true;
        } else if (action == QStringLiteral("Next")) {
            MediaRemote::self().sendCommand(commandNextTrack);
            handledAction = true;
        } else if (action == QStringLiteral("Previous")) {
            MediaRemote::self().sendCommand(commandPreviousTrack);
            handledAction = true;
        }
    }

    if (handledAction) {
        sendNowPlaying();
    } else if (np.get<bool>(QStringLiteral("requestNowPlaying"))) {
        sendNowPlaying(true);
    }
}

void MprisControlPlugin::sendPlayerList()
{
    NetworkPacket np(PACKET_TYPE_MPRIS);
    np.set(QStringLiteral("playerList"), QStringList{nowPlayingPlayer()});
    np.set(QStringLiteral("supportAlbumArtPayload"), false);
    sendPacket(np);
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
    body[QStringLiteral("player")] = nowPlayingPlayer();
    body[QStringLiteral("title")] = QString();
    body[QStringLiteral("artist")] = QString();
    body[QStringLiteral("album")] = QString();
    body[QStringLiteral("albumArtUrl")] = QString();
    body[QStringLiteral("url")] = QUrl();
    body[QStringLiteral("length")] = -1;
    body[QStringLiteral("pos")] = 0;
    body[QStringLiteral("isPlaying")] = m_hasLastKnownIsPlaying ? m_lastKnownIsPlaying : false;
    const bool canSendCommands = MediaRemote::self().canSendCommands();
    body[QStringLiteral("canPause")] = canSendCommands;
    body[QStringLiteral("canPlay")] = canSendCommands;
    body[QStringLiteral("canGoNext")] = canSendCommands;
    body[QStringLiteral("canGoPrevious")] = canSendCommands;
    body[QStringLiteral("canSeek")] = false;
    return body;
}

void MprisControlPlugin::requestNowPlaying(bool force)
{
    if (m_nowPlayingRequestInFlight) {
        m_forceSendAfterNowPlayingReply = m_forceSendAfterNowPlayingReply || force;
        return;
    }

    if (!MediaRemote::self().canReadNowPlayingInfo()) {
        const NowPlayingInfo nowPlaying = queryFallbackCascade(m_hasLastKnownIsPlaying, m_lastKnownIsPlaying);
        QVariantMap body = defaultNowPlayingBody();
        body[QStringLiteral("title")] = nowPlaying.title;
        body[QStringLiteral("artist")] = nowPlaying.artist;
        body[QStringLiteral("album")] = nowPlaying.album;
        body[QStringLiteral("length")] = nowPlaying.length;
        body[QStringLiteral("pos")] = nowPlaying.pos;
        if (nowPlaying.hasPlaybackRate) {
            m_lastKnownIsPlaying = nowPlaying.isPlaying;
            m_hasLastKnownIsPlaying = true;
            body[QStringLiteral("isPlaying")] = nowPlaying.isPlaying;
        }
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
        sendNowPlayingBody(defaultNowPlayingBody(), forceSend);
    });

    MediaRemote::self().getNowPlayingInfoAsync(^(CFDictionaryRef info) {
        if (!guard) {
            return;
        }

        const bool hasLastKnownIsPlaying = guard ? guard->m_hasLastKnownIsPlaying : false;
        const bool lastKnownIsPlaying = guard ? guard->m_lastKnownIsPlaying : false;
        NowPlayingInfo nowPlaying;
        @autoreleasepool {
            nowPlaying = readNowPlayingInfo(info);
        }
        if (!nowPlaying.hasUsefulMetadata) {
            mergeNowPlaying(nowPlaying, queryFallbackCascade(hasLastKnownIsPlaying, lastKnownIsPlaying));
        }

        QMetaObject::invokeMethod(guard.data(), [guard, requestId, nowPlaying]() {
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
            if (nowPlaying.hasUsefulMetadata) {
                body[QStringLiteral("title")] = nowPlaying.title;
                body[QStringLiteral("artist")] = nowPlaying.artist;
                body[QStringLiteral("album")] = nowPlaying.album;
                body[QStringLiteral("length")] = nowPlaying.length;
                body[QStringLiteral("pos")] = nowPlaying.pos;
                if (nowPlaying.hasPlaybackRate) {
                    guard->m_lastKnownIsPlaying = nowPlaying.isPlaying;
                    guard->m_hasLastKnownIsPlaying = true;
                    body[QStringLiteral("isPlaying")] = nowPlaying.isPlaying;
                }
                if (!guard->m_reportedNowPlayingInfo && nowPlaying.source != QStringLiteral("safe-default")) {
                    qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "Now-playing metadata available from" << nowPlaying.source;
                    guard->m_reportedNowPlayingInfo = true;
                }
            } else if (!guard->m_reportedEmptyNowPlayingInfo) {
                qCDebug(KDECONNECT_PLUGIN_MPRISCONTROL) << "MediaRemote now-playing metadata empty; using safe defaults";
                guard->m_reportedEmptyNowPlayingInfo = true;
            }

            guard->sendNowPlayingBody(body, forceSend);
        }, Qt::QueuedConnection);
    });
}

void MprisControlPlugin::sendNowPlayingBody(const QVariantMap &body, bool force)
{
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