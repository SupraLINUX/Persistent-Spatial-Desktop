#pragma once

#include <QObject>
#include <QPointF>
#include <QString>

class CompositorBridge;
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
        CompositorBridge *bridge,
        QString monitorName,
        QObject *parent = nullptr);

    [[nodiscard]] bool enabled() const noexcept;
    void setEnabled(bool enabled);

    [[nodiscard]] bool active() const;
    [[nodiscard]] bool idle() const noexcept;
    [[nodiscard]] QString monitorName() const;
    [[nodiscard]] QString lastError() const;

    bool shutdownAndReset(int timeoutMs = 1200);

signals:
    void enabledChanged();
    void activeChanged();
    void lastErrorChanged();
    void settled();

private:
    void handleBridgeAvailabilityChanged();
    void queueCurrentOffset();
    void dispatchPending();
    void setLastError(const QString &error);
    void emitSettledIfIdle();

    SpatialMotionController *m_motion = nullptr;
    CompositorBridge *m_bridge = nullptr;
    QString m_monitorName;
    bool m_enabled = false;
    bool m_hasPending = false;
    bool m_resetRequested = false;
    bool m_inFlightReset = false;
    bool m_transformMayBeOffset = false;
    quint64 m_inFlightCommandId = 0;
    QPointF m_pendingOffset;
    QString m_lastError;
};
