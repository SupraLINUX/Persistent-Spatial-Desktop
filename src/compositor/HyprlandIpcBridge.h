#pragma once

#include "compositor/CompositorBridge.h"

#include <QByteArray>
#include <QHash>
#include <QPointF>
#include <QLocalSocket>
#include <QTimer>

#include <functional>

class HyprlandIpcBridge final : public CompositorBridge
{
    Q_OBJECT
    Q_PROPERTY(QString instanceSignature READ instanceSignature NOTIFY instanceSignatureChanged)

public:
    explicit HyprlandIpcBridge(QObject *parent = nullptr);

    [[nodiscard]] QString backendName() const override;
    [[nodiscard]] QString instanceSignature() const;

    [[nodiscard]] bool spatialTransformAvailable() const override;
    quint64 setSpatialTransformOffset(const QString &monitorName, double x, double y) override;
    quint64 resetSpatialTransformOffset(const QString &monitorName) override;

    void start() override;
    Q_INVOKABLE void refreshAll() override;
    Q_INVOKABLE void refreshCapabilities();

signals:
    void instanceSignatureChanged();
    void experimentalSpatialGestureBegin(const QString &monitorName);
    void experimentalSpatialGestureUpdate(const QString &monitorName, double deltaX, double deltaY);
    void experimentalSpatialGestureEnd(const QString &monitorName, double velocityX, double velocityY, bool cancelled);

private:
    enum RefreshFlag : quint8 {
        RefreshNone = 0,
        RefreshMonitors = 1 << 0,
        RefreshWorkspaces = 1 << 1,
        RefreshWindows = 1 << 2,
        RefreshEverything = RefreshMonitors | RefreshWorkspaces | RefreshWindows,
    };

    using ResponseCallback = std::function<void(const QByteArray &)>;

    void discoverInstance();
    void connectEventStream();
    void handleEventData();
    void handleEventLine(const QByteArray &line);
    void scheduleRefresh(quint8 flags);
    void refreshPending();
    void refreshMonitors();
    void refreshWorkspaces();
    void refreshWindows();
    void requestJson(const QByteArray &request, ResponseCallback callback, bool reportParseErrors = true);
    void requestText(const QByteArray &request, ResponseCallback callback);
    void cancelSpatialGestures();

    struct GestureSample {
        quint32 timeMs = 0;
        QPointF velocity;
    };

    QString m_instanceSignature;
    QString m_commandSocketPath;
    QString m_eventSocketPath;
    QLocalSocket m_eventSocket;
    QByteArray m_eventBuffer;
    QTimer m_refreshTimer;
    QTimer m_reconnectTimer;
    quint8 m_pendingRefresh = RefreshNone;
    QHash<QString, GestureSample> m_gestureSamples;
};
