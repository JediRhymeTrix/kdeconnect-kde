/**
 * SPDX-FileCopyrightText: 2026 KDE Connect contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#pragma once

#include <core/kdeconnectplugin.h>

#include <QByteArray>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

class QTimer;

#define PACKET_TYPE_MPRIS QStringLiteral("kdeconnect.mpris")

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

class MprisControlPlugin : public KdeConnectPlugin
{
    Q_OBJECT

public:
    explicit MprisControlPlugin(QObject *parent, const QVariantList &args);

    void receivePacket(const NetworkPacket &np) override;

private:
    // One entry per application that owned now playing during this session, plus one
    // "Now Playing" system entry that always mirrors the elected application and is
    // controllable even when player identification does not work.
    struct SessionPlayer {
        QString name;
        QString bundleIdentifier;
        qint64 processIdentifier = 0;
        bool isActive = false;
        bool isSystem = false;
        bool hasState = false;
        bool isRunning = true;
        NowPlayingInfo lastInfo;
        QVariantMap lastBody;
        QByteArray artworkBytes;
        QByteArray artworkHash;
        QString artworkUrl;
        int artworkRevision = 0;
    };

    void sendPlayerList();
    void sendNowPlaying(bool force = true, const QString &player = QString());
    void pollNowPlaying();
    void requestNowPlaying(bool force);
    void sendNowPlayingBody(QVariantMap body, bool force, bool estimateProgress);
    void sendLiveBodies(const NowPlayingInfo &nowPlaying, bool force);
    void sendFrozenPlayerBody(const SessionPlayer &entry, bool force);
    bool sendAlbumArt(const QString &requestedAlbumArtUrl);
    QVariantMap playerBody(const QString &playerName, bool controllable) const;
    bool handleAction(const QString &action, const QString &player);
    bool handleSeekPacket(const NetworkPacket &np, const QString &player);
    QString currentPlayerName() const;
    bool isKnownPlayerName(const QString &player) const;
    bool sendMediaControlCommand(const QStringList &arguments);
    NowPlayingInfo queryMediaControl();
    void updateActivePlayer(const NowPlayingInfo &nowPlaying);
    void rememberSupportedSource(const NowPlayingInfo &nowPlaying);
    NowPlayingInfo selectFallbackNowPlaying(const NowPlayingInfo &supportedApp, const NowPlayingInfo &genericFallback) const;
    void applyNowPlayingInfo(QVariantMap &body, const NowPlayingInfo &nowPlaying, qint64 sampleTime, SessionPlayer &entry);
    void updateAlbumArt(const QByteArray &artworkBytes, SessionPlayer &entry);
    void updatePlaybackProgress(bool hasPosition, qlonglong position, bool hasPlaybackRate, double playbackRate, qint64 sampleTime);
    void estimatePlaybackProgress(QVariantMap &body) const;

    SessionPlayer *sessionPlayer(const QString &name);
    SessionPlayer *systemPlayer();
    void pruneStoppedPlayers();

    bool m_lastKnownIsPlaying = false;
    bool m_hasLastKnownIsPlaying = false;
    bool m_nowPlayingRequestInFlight = false;
    bool m_forceSendAfterNowPlayingReply = false;
    bool m_reportedNowPlayingInfo = false;
    bool m_reportedNowPlayingTimeout = false;
    bool m_reportedSeekUnsupported = false;
    bool m_reportedCommandUnavailable = false;
    bool m_hasLastPosition = false;
    int m_nowPlayingRequestId = 0;
    qlonglong m_lastPosition = 0;
    qint64 m_lastPositionSampleTime = 0;
    double m_lastPlaybackRate = 0.0;
    QString m_lastSupportedSource;
    QString m_mediaControlProgram;
    QString m_mediaControlArtworkItemId;
    bool m_mediaControlArtworkValid = false;
    bool m_reportedMediaControlFailure = false;
    QList<SessionPlayer> m_sessionPlayers;
    QTimer *m_pollTimer = nullptr;
};
