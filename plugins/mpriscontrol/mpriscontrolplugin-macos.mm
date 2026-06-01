/**
 * SPDX-FileCopyrightText: 2026 KDE Connect contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#include "mpriscontrolplugin-macos.h"

#include "plugin_mpriscontrol_debug.h"

#include <KPluginFactory>

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

    bool sendCommand(int command) const
    {
        if (!m_sendCommand) {
            return false;
        }
        return m_sendCommand(command, nullptr);
    }

    CFDictionaryRef copyNowPlayingInfo() const
    {
        if (!m_getNowPlayingInfo) {
            return nullptr;
        }

        struct State {
            ~State()
            {
                if (info) {
                    CFRelease(info);
                }
            }
            CFDictionaryRef info = nullptr;
        };

        auto state = std::make_shared<State>();
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        m_getNowPlayingInfo(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(CFDictionaryRef info) {
            if (info) {
                state->info = static_cast<CFDictionaryRef>(CFRetain(info));
            }
            dispatch_semaphore_signal(semaphore);
        });

        const long timeout = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        if (timeout != 0) {
            return nullptr;
        }
        CFDictionaryRef info = state->info;
        state->info = nullptr;
        return info;
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
}

MprisControlPlugin::MprisControlPlugin(QObject *parent, const QVariantList &args)
    : KdeConnectPlugin(parent, args)
{
    @autoreleasepool {
        MediaRemote::self();
    }
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

    if (handledAction || np.get<bool>(QStringLiteral("requestNowPlaying"))) {
        sendNowPlaying();
    }
}

void MprisControlPlugin::sendPlayerList()
{
    NetworkPacket np(PACKET_TYPE_MPRIS);
    np.set(QStringLiteral("playerList"), QStringList{nowPlayingPlayer()});
    np.set(QStringLiteral("supportAlbumArtPayload"), false);
    sendPacket(np);
}

void MprisControlPlugin::sendNowPlaying()
{
    @autoreleasepool {
    NetworkPacket np(PACKET_TYPE_MPRIS);
    np.set(QStringLiteral("player"), nowPlayingPlayer());
    np.set(QStringLiteral("title"), QString());
    np.set(QStringLiteral("artist"), QString());
    np.set(QStringLiteral("album"), QString());
    np.set(QStringLiteral("albumArtUrl"), QString());
    np.set(QStringLiteral("url"), QUrl());
    np.set(QStringLiteral("length"), -1);
    np.set(QStringLiteral("pos"), 0);
    np.set(QStringLiteral("isPlaying"), m_hasLastKnownIsPlaying ? m_lastKnownIsPlaying : false);
    const bool canSendCommands = MediaRemote::self().canSendCommands();
    np.set(QStringLiteral("canPause"), canSendCommands);
    np.set(QStringLiteral("canPlay"), canSendCommands);
    np.set(QStringLiteral("canGoNext"), canSendCommands);
    np.set(QStringLiteral("canGoPrevious"), canSendCommands);
    np.set(QStringLiteral("canSeek"), false);

    CFDictionaryRef info = MediaRemote::self().copyNowPlayingInfo();
    if (info) {
        const auto value = [info](CFStringRef key) -> CFTypeRef {
            return key ? CFDictionaryGetValue(info, key) : nullptr;
        };

        np.set(QStringLiteral("title"), cfStringToQString(value(MediaRemote::self().keyTitle())));
        np.set(QStringLiteral("artist"), cfStringToQString(value(MediaRemote::self().keyArtist())));
        np.set(QStringLiteral("album"), cfStringToQString(value(MediaRemote::self().keyAlbum())));

        double number = 0;
        if (cfNumberToDouble(value(MediaRemote::self().keyDuration()), &number)) {
            np.set(QStringLiteral("length"), secondsToMilliseconds(number, -1));
        }
        if (cfNumberToDouble(value(MediaRemote::self().keyElapsedTime()), &number)) {
            np.set(QStringLiteral("pos"), secondsToMilliseconds(number));
        }
        if (cfNumberToDouble(value(MediaRemote::self().keyPlaybackRate()), &number)) {
            m_lastKnownIsPlaying = number > 0.01;
            m_hasLastKnownIsPlaying = true;
            np.set(QStringLiteral("isPlaying"), m_lastKnownIsPlaying);
        }

        CFRelease(info);
    }

    if (!m_hasLastKnownIsPlaying) {
        bool ok = false;
        const bool playing = MediaRemote::self().queryIsPlaying(&ok);
        if (ok) {
            m_lastKnownIsPlaying = playing;
            m_hasLastKnownIsPlaying = true;
            np.set(QStringLiteral("isPlaying"), m_lastKnownIsPlaying);
        }
    }

    sendPacket(np);
    }
}

#include "moc_mpriscontrolplugin-macos.cpp"
#include "mpriscontrolplugin-macos.moc"