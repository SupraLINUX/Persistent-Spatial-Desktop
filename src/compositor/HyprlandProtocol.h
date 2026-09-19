#pragma once

#include <QByteArray>
#include <QPair>
#include <QString>
#include <QVariantList>

class HyprlandProtocol final
{
public:
    struct Event {
        QString name;
        QString payload;
        bool valid = false;
    };

    struct SpatialGestureBegin {
        QString monitorName;
        quint32 timeMs = 0;
        bool valid = false;
    };

    struct SpatialGestureUpdate {
        QString monitorName;
        double deltaX = 0.0;
        double deltaY = 0.0;
        quint32 timeMs = 0;
        bool valid = false;
    };

    struct SpatialGestureEnd {
        QString monitorName;
        bool cancelled = false;
        quint32 timeMs = 0;
        bool valid = false;
    };

    [[nodiscard]] static QPair<QString, QString> socketPaths(
        const QString &runtimeDirectory,
        const QString &instanceSignature);

    [[nodiscard]] static Event parseEventLine(const QByteArray &line);
    [[nodiscard]] static SpatialGestureBegin parseSpatialGestureBegin(const QString &payload);
    [[nodiscard]] static SpatialGestureUpdate parseSpatialGestureUpdate(const QString &payload);
    [[nodiscard]] static SpatialGestureEnd parseSpatialGestureEnd(const QString &payload);
    [[nodiscard]] static QVariantList parseMonitors(const QByteArray &json, QString *error = nullptr);
    [[nodiscard]] static QVariantList parseWorkspaces(const QByteArray &json, QString *error = nullptr);
    [[nodiscard]] static QVariantList parseWindows(const QByteArray &json, QString *error = nullptr);

private:
    HyprlandProtocol() = delete;
};
