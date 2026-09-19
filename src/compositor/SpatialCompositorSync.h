#pragma once

#include <QObject>
#include <QPointF>
#include <QString>

class HyprlandIpcBridge;
class SpatialMotionController;

class SpatialCompositorSync final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    Q_PROPERTY(QString monitorName READ monitorName CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    SpatialCompositorSync(
        SpatialMotionController *motion,
        HyprlandIpcBridge *bridge,
        QString monitorName,
        QObject *parent = nullptr);

    [[nodiscard]] bool enabled() const noexcept;
    void setEnabled(bool enabled);

    [[nodiscard]] bool active() const;
    [[nodiscard]] QString monitorName() const;
    [[nodiscard]] QString lastError() const;

signals:
    void enabledChanged();
    void activeChanged();
    void lastErrorChanged();

private:
    void queueCurrentOffset();
    void dispatchPending();
    void setLastError(const QString &error);

    SpatialMotionController *m_motion = nullptr;
    HyprlandIpcBridge *m_bridge = nullptr;
    QString m_monitorName;
    bool m_enabled = false;
    bool m_inFlight = false;
    bool m_hasPending = false;
    QPointF m_pendingOffset;
    QString m_lastError;
};
