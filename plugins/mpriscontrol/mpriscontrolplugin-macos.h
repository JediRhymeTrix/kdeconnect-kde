/**
 * SPDX-FileCopyrightText: 2026 KDE Connect contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

#pragma once

#include <core/kdeconnectplugin.h>

#include <QStringList>
#include <QUrl>

#define PACKET_TYPE_MPRIS QStringLiteral("kdeconnect.mpris")

class MprisControlPlugin : public KdeConnectPlugin
{
    Q_OBJECT

public:
    explicit MprisControlPlugin(QObject *parent, const QVariantList &args);

    void receivePacket(const NetworkPacket &np) override;

private:
    void sendPlayerList();
    void sendNowPlaying();

    bool m_lastKnownIsPlaying = false;
    bool m_hasLastKnownIsPlaying = false;
};