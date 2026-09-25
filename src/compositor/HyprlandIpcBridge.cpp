#include "compositor/HyprlandIpcBridge.h"

#include "compositor/HyprlandProtocol.h"

#include <QEventLoop>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QStandardPaths>

#include <algorithm>
#include <memory>
#include <utility>

HyprlandIpcBridge::HyprlandIpcBridge(QObject *parent)
    : CompositorBridge(parent)
{
    m_refreshTimer.setSingleShot(true);
    m_refreshTimer.setInterval(25);
    connect(&m_refreshTimer, &QTimer::timeout, this, &HyprlandIpcBridge::refreshPending);

    m_reconnectTimer.setSingleShot(true);
    m_reconnectTimer.setInterval(1000);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &HyprlandIpcBridge::connectEventStream);

    connect(&m_eventSocket, &QLocalSocket::connected, this, [this] {
        setEventStreamConnected(true);
        setLastError({});
        scheduleRefresh(RefreshEverything);
        refreshCapabilities();
    });

    connect(&m_eventSocket, &QLocalSocket::readyRead, this, &HyprlandIpcBridge::handleEventData);

    connect(&m_eventSocket, &QLocalSocket::disconnected, this, [this] {
        cancelSpatialGestures();
        setExperimentalSpatialGesturesArmed(false);
        setEventStreamConnected(false);
        setCapabilities({});
        if (available())
            m_reconnectTimer.start();
    });

    connect(&m_eventSocket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError error) {
        if (error == QLocalSocket::PeerClosedError)
            return;

        cancelSpatialGestures();
        setExperimentalSpatialGesturesArmed(false);
        setEventStreamConnected(false);
        setCapabilities({});
        setLastError(QStringLiteral("Hyprland event socket: %1").arg(m_eventSocket.errorString()));
        if (available() && !m_reconnectTimer.isActive())
            m_reconnectTimer.start();
    });
}

QString HyprlandIpcBridge::backendName() const
{
    return QStringLiteral("hyprland");
}

QString HyprlandIpcBridge::instanceSignature() const
{
    return m_instanceSignature;
}

bool HyprlandIpcBridge::spatialTransformAvailable() const
{
    if (!available())
        return false;

    const QVariantMap currentCapabilities = capabilities();
    return currentCapabilities.value(QStringLiteral("spatialRenderOffsetExperimental")).toBool()
        && currentCapabilities.value(QStringLiteral("monitorTargeting")).toBool()
        && currentCapabilities.value(QStringLiteral("lifecycleEventsExperimental")).toBool();
}

void HyprlandIpcBridge::start()
{
    discoverInstance();
    if (!available())
        return;

    refreshAll();
    refreshCapabilities();
    connectEventStream();
}

void HyprlandIpcBridge::refreshAll()
{
    scheduleRefresh(RefreshEverything);
}

void HyprlandIpcBridge::refreshCapabilities()
{
    if (!available()) {
        setExperimentalSpatialGesturesArmed(false);
        setCapabilities({});
        return;
    }

    requestJson("j/psd-plugin", [this](const QByteArray &json) {
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            setExperimentalSpatialGesturesArmed(false);
            setCapabilities({});
            return;
        }

        const QJsonObject object = document.object();
        QVariantMap capabilities;
        capabilities.insert(QStringLiteral("pluginProtocolVersion"),
                            object.value(QStringLiteral("protocolVersion")).toInt());
        capabilities.insert(QStringLiteral("pluginVersion"),
                            object.value(QStringLiteral("pluginVersion")).toString());
        capabilities.insert(QStringLiteral("spatialRenderOffsetExperimental"),
                            object.value(QStringLiteral("spatialRenderOffsetExperimental")).toBool());
        capabilities.insert(QStringLiteral("monitorTargeting"),
                            object.value(QStringLiteral("monitorTargeting")).toBool());
        capabilities.insert(QStringLiteral("fourFingerGestureEventsExperimental"),
                            object.value(QStringLiteral("fourFingerGestureEventsExperimental")).toBool());
        capabilities.insert(QStringLiteral("lifecycleEventsExperimental"),
                            object.value(QStringLiteral("lifecycleEventsExperimental")).toBool());
        setCapabilities(std::move(capabilities));
        synchronizeExperimentalSpatialGestures();
    }, false);
}

void HyprlandIpcBridge::setExperimentalSpatialGesturesEnabled(bool enabled)
{
    m_experimentalSpatialGesturesDesired = enabled;
    synchronizeExperimentalSpatialGestures();
}

bool HyprlandIpcBridge::experimentalSpatialGesturesArmed() const noexcept
{
    return m_experimentalSpatialGesturesArmed;
}

bool HyprlandIpcBridge::waitForExperimentalSpatialGesturesArmed(
    bool armed, int timeoutMs)
{
    if (m_experimentalSpatialGesturesArmed == armed)
        return true;

    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);

    connect(this, &HyprlandIpcBridge::experimentalSpatialGesturesArmedChanged,
            &loop, [this, armed, &loop] {
        if (m_experimentalSpatialGesturesArmed == armed)
            loop.quit();
    });
    connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);

    synchronizeExperimentalSpatialGestures();

    const int boundedTimeoutMs = std::max(0, timeoutMs);
    if (boundedTimeoutMs > 0) {
        timer.start(boundedTimeoutMs);
        loop.exec();
    }

    return m_experimentalSpatialGesturesArmed == armed;
}

void HyprlandIpcBridge::setExperimentalSpatialGesturesArmed(bool armed)
{
    if (m_experimentalSpatialGesturesArmed == armed)
        return;

    m_experimentalSpatialGesturesArmed = armed;
    emit experimentalSpatialGesturesArmedChanged();
}

void HyprlandIpcBridge::synchronizeExperimentalSpatialGestures()
{
    const bool supported =
        available()
        && capabilities()
               .value(QStringLiteral("fourFingerGestureEventsExperimental"))
               .toBool();

    if (!supported) {
        setExperimentalSpatialGesturesArmed(false);
        return;
    }

    if (m_experimentalSpatialGestureRequestInFlight
        || m_experimentalSpatialGesturesArmed
            == m_experimentalSpatialGesturesDesired) {
        return;
    }

    const bool target = m_experimentalSpatialGesturesDesired;
    m_experimentalSpatialGestureRequestInFlight = true;

    requestText(
        QByteArrayLiteral("dispatch plugin:psd:gesture-events ")
            + (target ? QByteArrayLiteral("1") : QByteArrayLiteral("0")),
        [this, target](const QByteArray &response) {
            m_experimentalSpatialGestureRequestInFlight = false;

            const QString result = QString::fromUtf8(response).trimmed();
            if (result == QStringLiteral("ok")) {
                setExperimentalSpatialGesturesArmed(target);
            } else {
                setLastError(
                    QStringLiteral("PSD spatial gesture subscription failed: %1")
                        .arg(result));
            }

            if (m_experimentalSpatialGesturesArmed
                != m_experimentalSpatialGesturesDesired) {
                QTimer::singleShot(
                    0, this,
                    &HyprlandIpcBridge::synchronizeExperimentalSpatialGestures);
            }
        });
}

quint64 HyprlandIpcBridge::setSpatialTransformOffset(
    const QString &monitorName, double x, double y)
{
    const quint64 commandId = allocateSpatialTransformCommandId();

    if (!spatialTransformAvailable()) {
        QTimer::singleShot(0, this, [this, commandId, monitorName] {
            emit spatialTransformCommandFinished(
                commandId,
                monitorName,
                false,
                QStringLiteral("PSD Hyprland spatial plugin capability is unavailable"));
        });
        return commandId;
    }

    const QByteArray request =
        QByteArrayLiteral("dispatch plugin:psd:offset ")
        + monitorName.toUtf8()
        + ' '
        + QByteArray::number(x, 'f', 3)
        + ' '
        + QByteArray::number(y, 'f', 3);

    requestText(request, [this, commandId, monitorName](const QByteArray &response) {
        const QString result = QString::fromUtf8(response).trimmed();
        const bool success = result == QStringLiteral("ok");
        if (!success)
            refreshCapabilities();
        emit spatialTransformCommandFinished(commandId, monitorName, success, result);
    });

    return commandId;
}

quint64 HyprlandIpcBridge::resetSpatialTransformOffset(const QString &monitorName)
{
    const quint64 commandId = allocateSpatialTransformCommandId();

    if (!spatialTransformAvailable()) {
        QTimer::singleShot(0, this, [this, commandId, monitorName] {
            emit spatialTransformCommandFinished(
                commandId,
                monitorName,
                false,
                QStringLiteral("PSD Hyprland spatial plugin capability is unavailable"));
        });
        return commandId;
    }

    requestText(QByteArrayLiteral("dispatch plugin:psd:reset ") + monitorName.toUtf8(),
                [this, commandId, monitorName](const QByteArray &response) {
        const QString result = QString::fromUtf8(response).trimmed();
        const bool success = result == QStringLiteral("ok");
        if (!success)
            refreshCapabilities();
        emit spatialTransformCommandFinished(commandId, monitorName, success, result);
    });

    return commandId;
}

void HyprlandIpcBridge::discoverInstance()
{
    const QString signature = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
    QString runtimeDirectory = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtimeDirectory.isEmpty())
        runtimeDirectory = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);

    if (signature.isEmpty() || runtimeDirectory.isEmpty()) {
        setAvailable(false);
        setCapabilities({});
        setLastError(QStringLiteral("Hyprland IPC environment is unavailable"));
        return;
    }

    const auto paths = HyprlandProtocol::socketPaths(runtimeDirectory, signature);
    if (paths.first.isEmpty() || paths.second.isEmpty()) {
        setAvailable(false);
        setCapabilities({});
        setLastError(QStringLiteral("Unable to resolve Hyprland IPC socket paths"));
        return;
    }

    m_instanceSignature = signature;
    m_commandSocketPath = paths.first;
    m_eventSocketPath = paths.second;
    emit instanceSignatureChanged();

    const bool commandExists = QFileInfo::exists(m_commandSocketPath);
    const bool eventExists = QFileInfo::exists(m_eventSocketPath);
    setAvailable(commandExists && eventExists);

    if (!available()) {
        setCapabilities({});
        setLastError(QStringLiteral("Hyprland IPC sockets are not present for instance %1")
                         .arg(m_instanceSignature));
        return;
    }

    setLastError({});
}

void HyprlandIpcBridge::connectEventStream()
{
    if (!available())
        return;

    if (m_eventSocket.state() != QLocalSocket::UnconnectedState)
        m_eventSocket.abort();

    m_eventBuffer.clear();
    m_eventSocket.connectToServer(m_eventSocketPath, QIODevice::ReadOnly);
}

void HyprlandIpcBridge::handleEventData()
{
    m_eventBuffer.append(m_eventSocket.readAll());

    qsizetype newline = -1;
    while ((newline = m_eventBuffer.indexOf('\n')) >= 0) {
        const QByteArray line = m_eventBuffer.left(newline);
        m_eventBuffer.remove(0, newline + 1);
        handleEventLine(line);
    }
}

void HyprlandIpcBridge::handleEventLine(const QByteArray &line)
{
    const HyprlandProtocol::Event event = HyprlandProtocol::parseEventLine(line);
    if (!event.valid)
        return;

    emit compositorEvent(event.name, event.payload);

    if (event.name == QStringLiteral("psdpluginready")) {
        QTimer::singleShot(0, this, &HyprlandIpcBridge::refreshCapabilities);
        return;
    }

    if (event.name == QStringLiteral("psdpluginunloading")) {
        cancelSpatialGestures();
        setExperimentalSpatialGesturesArmed(false);
        setCapabilities({});
        return;
    }

    if (event.name == QStringLiteral("psdgesturebegin")) {
        const auto gesture = HyprlandProtocol::parseSpatialGestureBegin(event.payload);
        if (!gesture.valid)
            return;

        m_gestureSamples.insert(gesture.monitorName, GestureSample{gesture.timeMs, {}});
        emit experimentalSpatialGestureBegin(gesture.monitorName);
        return;
    }

    if (event.name == QStringLiteral("psdgestureupdate")) {
        const auto gesture = HyprlandProtocol::parseSpatialGestureUpdate(event.payload);
        if (!gesture.valid)
            return;

        GestureSample &sample = m_gestureSamples[gesture.monitorName];
        if (sample.timeMs != 0) {
            const quint32 elapsedMs = gesture.timeMs - sample.timeMs;
            if (elapsedMs > 0 && elapsedMs <= 250) {
                const QPointF instantaneous(
                    gesture.deltaX * 1000.0 / static_cast<double>(elapsedMs),
                    gesture.deltaY * 1000.0 / static_cast<double>(elapsedMs));
                sample.velocity = sample.velocity.isNull()
                    ? instantaneous
                    : (sample.velocity * 0.35) + (instantaneous * 0.65);
            }
        }
        sample.timeMs = gesture.timeMs;

        emit experimentalSpatialGestureUpdate(
            gesture.monitorName, gesture.deltaX, gesture.deltaY);
        return;
    }

    if (event.name == QStringLiteral("psdgestureend")) {
        const auto gesture = HyprlandProtocol::parseSpatialGestureEnd(event.payload);
        if (!gesture.valid)
            return;

        const GestureSample sample = m_gestureSamples.take(gesture.monitorName);
        emit experimentalSpatialGestureEnd(
            gesture.monitorName, sample.velocity.x(), sample.velocity.y(), gesture.cancelled);
        return;
    }
    if (event.name.startsWith(QStringLiteral("monitor"))
        || event.name.startsWith(QStringLiteral("focusedmon"))) {
        scheduleRefresh(RefreshMonitors | RefreshWorkspaces);
        return;
    }

    if (event.name.startsWith(QStringLiteral("workspace"))
        || event.name.startsWith(QStringLiteral("createworkspace"))
        || event.name.startsWith(QStringLiteral("destroyworkspace"))
        || event.name.startsWith(QStringLiteral("moveworkspace"))
        || event.name.startsWith(QStringLiteral("renameworkspace"))
        || event.name.startsWith(QStringLiteral("activespecial"))) {
        scheduleRefresh(RefreshMonitors | RefreshWorkspaces);
        return;
    }

    if (event.name == QStringLiteral("fullscreen")) {
        // Hyprland 0.53.3 updates window/workspace fullscreen state before
        // emitting this event, so one coalesced refresh is sufficient.
        scheduleRefresh(RefreshWindows | RefreshWorkspaces);
        return;
    }

    if (event.name.startsWith(QStringLiteral("closewindow"))
        || event.name.startsWith(QStringLiteral("movewindow"))) {
        // Closing/moving a fullscreen target can change workspace aggregate
        // state even if no useful client remains to describe it.
        scheduleRefresh(RefreshWindows | RefreshWorkspaces);
        return;
    }

    if (event.name.startsWith(QStringLiteral("openwindow"))
        || event.name.startsWith(QStringLiteral("activewindow"))
        || event.name.startsWith(QStringLiteral("windowtitle"))
        || event.name == QStringLiteral("changefloatingmode")
        || event.name == QStringLiteral("pin")
        || event.name == QStringLiteral("minimized")) {
        scheduleRefresh(RefreshWindows);
        return;
    }

    if (event.name == QStringLiteral("configreloaded")) {
        scheduleRefresh(RefreshEverything);
        refreshCapabilities();
    }
}

void HyprlandIpcBridge::scheduleRefresh(quint8 flags)
{
    if (!available())
        return;

    m_pendingRefresh |= flags;
    if (!m_refreshTimer.isActive())
        m_refreshTimer.start();
}

void HyprlandIpcBridge::refreshPending()
{
    const quint8 flags = m_pendingRefresh;
    m_pendingRefresh = RefreshNone;

    if (flags & RefreshMonitors)
        refreshMonitors();
    if (flags & RefreshWorkspaces)
        refreshWorkspaces();
    if (flags & RefreshWindows)
        refreshWindows();
}

void HyprlandIpcBridge::refreshMonitors()
{
    requestJson("j/monitors", [this](const QByteArray &json) {
        QString error;
        const QVariantList monitors = HyprlandProtocol::parseMonitors(json, &error);
        if (!error.isEmpty()) {
            setLastError(QStringLiteral("Invalid Hyprland monitor response: %1").arg(error));
            return;
        }
        setMonitors(monitors);
    });
}

void HyprlandIpcBridge::refreshWorkspaces()
{
    requestJson("j/workspaces", [this](const QByteArray &json) {
        QString error;
        const QVariantList workspaces = HyprlandProtocol::parseWorkspaces(json, &error);
        if (!error.isEmpty()) {
            setLastError(QStringLiteral("Invalid Hyprland workspace response: %1").arg(error));
            return;
        }
        setWorkspaces(workspaces);
    });
}

void HyprlandIpcBridge::refreshWindows()
{
    requestJson("j/clients", [this](const QByteArray &json) {
        QString error;
        const QVariantList windows = HyprlandProtocol::parseWindows(json, &error);
        if (!error.isEmpty()) {
            setLastError(QStringLiteral("Invalid Hyprland client response: %1").arg(error));
            return;
        }
        setWindows(windows);
    });
}

void HyprlandIpcBridge::requestJson(
    const QByteArray &request, ResponseCallback callback, bool reportParseErrors)
{
    if (!available())
        return;

    auto *socket = new QLocalSocket(this);
    auto buffer = std::make_shared<QByteArray>();
    auto completed = std::make_shared<bool>(false);
    auto *timeout = new QTimer(socket);
    timeout->setSingleShot(true);
    timeout->setInterval(1000);

    const auto finish = [socket, timeout, completed](bool abortSocket) {
        if (*completed)
            return false;

        *completed = true;
        timeout->stop();
        if (abortSocket)
            socket->abort();
        else
            socket->disconnectFromServer();
        socket->deleteLater();
        return true;
    };

    connect(timeout, &QTimer::timeout, this, [this, finish, reportParseErrors] {
        if (finish(true) && reportParseErrors)
            setLastError(QStringLiteral("Hyprland IPC request timed out"));
    });

    connect(socket, &QLocalSocket::connected, this, [socket, request, timeout] {
        socket->write(request);
        socket->flush();
        timeout->start();
    });

    connect(socket, &QLocalSocket::readyRead, this,
            [this, socket, buffer, callback = std::move(callback), finish, reportParseErrors] {
        buffer->append(socket->readAll());

        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(*buffer, &parseError);
        if (parseError.error == QJsonParseError::UnterminatedObject
            || parseError.error == QJsonParseError::UnterminatedArray
            || parseError.error == QJsonParseError::IllegalValue) {
            if (!reportParseErrors && !buffer->startsWith('{') && !buffer->startsWith('[')) {
                finish(false);
                setCapabilities({});
            }
            return;
        }

        if (parseError.error != QJsonParseError::NoError) {
            if (finish(false) && reportParseErrors)
                setLastError(QStringLiteral("Hyprland IPC returned invalid JSON: %1")
                                 .arg(parseError.errorString()));
            return;
        }

        if (finish(false)) {
            if (reportParseErrors)
                setLastError({});
            callback(*buffer);
        }
    });

    connect(socket, &QLocalSocket::errorOccurred, this,
            [this, socket, finish, reportParseErrors](QLocalSocket::LocalSocketError error) {
        if (error == QLocalSocket::PeerClosedError)
            return;

        if (finish(true) && reportParseErrors)
            setLastError(QStringLiteral("Hyprland command socket: %1").arg(socket->errorString()));
    });

    socket->connectToServer(m_commandSocketPath, QIODevice::ReadWrite);
}


void HyprlandIpcBridge::cancelSpatialGestures()
{
    const auto monitorNames = m_gestureSamples.keys();
    m_gestureSamples.clear();

    for (const QString &monitorName : monitorNames)
        emit experimentalSpatialGestureEnd(monitorName, 0.0, 0.0, true);
}

void HyprlandIpcBridge::requestText(const QByteArray &request, ResponseCallback callback)
{
    if (!available()) {
        callback(QByteArrayLiteral("PSD: Hyprland IPC unavailable"));
        return;
    }

    auto *socket = new QLocalSocket(this);
    auto completed = std::make_shared<bool>(false);
    auto sharedCallback = std::make_shared<ResponseCallback>(std::move(callback));
    auto *timeout = new QTimer(socket);
    timeout->setSingleShot(true);
    timeout->setInterval(1000);

    const auto finish = [socket, timeout, completed]() {
        if (*completed)
            return false;
        *completed = true;
        timeout->stop();
        socket->disconnectFromServer();
        socket->deleteLater();
        return true;
    };

    connect(timeout, &QTimer::timeout, this, [sharedCallback, finish] {
        if (finish())
            (*sharedCallback)(QByteArrayLiteral("PSD: Hyprland IPC request timed out"));
    });

    connect(socket, &QLocalSocket::connected, this, [socket, request, timeout] {
        socket->write(request);
        socket->flush();
        timeout->start();
    });

    connect(socket, &QLocalSocket::readyRead, this,
            [socket, sharedCallback, finish] {
        const QByteArray response = socket->readAll();
        if (finish())
            (*sharedCallback)(response);
    });

    connect(socket, &QLocalSocket::errorOccurred, this,
            [socket, sharedCallback, finish](QLocalSocket::LocalSocketError error) {
        if (error == QLocalSocket::PeerClosedError)
            return;
        if (finish())
            (*sharedCallback)(QByteArrayLiteral("PSD: ") + socket->errorString().toUtf8());
    });

    socket->connectToServer(m_commandSocketPath, QIODevice::ReadWrite);
}
