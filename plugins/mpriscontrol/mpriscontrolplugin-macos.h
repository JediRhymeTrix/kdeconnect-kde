/**
 * SPDX-FileCopyrightText: 2026 KDE Connect contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#pragma once

#include <core/kdeconnectplugin.h>

#include <QStringList>
#include <QUrl>
#include <QVariantMap>

class QTimer;

#define PACKET_TYPE_MPRIS QStringLiteral("kdeconnect.mpris")

class MprisControlPlugin : public KdeConnectPlugin
{
    Q_OBJECT

public:
    explicit MprisControlPlugin(QObject *parent, const QVariantList &args);

    void receivePacket(const NetworkPacket &np) override;

private:
    void sendPlayerList();
    void sendNowPlaying(bool force = true);
    void pollNowPlaying();
    void requestNowPlaying(bool force);
    void sendNowPlayingBody(QVariantMap body, bool force);
    QVariantMap defaultNowPlayingBody() const;
    void updatePlaybackProgress(bool hasPosition, qlonglong position, bool hasPlaybackRate, double playbackRate, qint64 sampleTime);
    void estimatePlaybackProgress(QVariantMap &body) const;

    bool m_lastKnownIsPlaying = false;
    bool m_hasLastKnownIsPlaying = false;
    bool m_hasLastNowPlayingBody = false;
    bool m_nowPlayingRequestInFlight = false;
    bool m_forceSendAfterNowPlayingReply = false;
    bool m_reportedEmptyNowPlayingInfo = false;
    bool m_reportedNowPlayingInfo = false;
    bool m_reportedNowPlayingTimeout = false;
    bool m_reportedSeekUnsupported = false;
    bool m_hasLastPosition = false;
    int m_nowPlayingRequestId = 0;
    qlonglong m_lastPosition = 0;
    qint64 m_lastPositionSampleTime = 0;
    double m_lastPlaybackRate = 0.0;
    QVariantMap m_lastNowPlayingBody;
    QTimer *m_pollTimer = nullptr;
};
