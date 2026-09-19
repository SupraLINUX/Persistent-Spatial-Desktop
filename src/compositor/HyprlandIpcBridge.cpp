#include "compositor/HyprlandIpcBridge.h"

#include "compositor/HyprlandProtocol.h"

#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QPointer>
#include <QStandardPaths>

#include <memory>

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
    });

    connect(&m_eventSocket, &QLocalSocket::readyRead, this, &HyprlandIpcBridge::handleEventData);

    connect(&m_eventSocket, &QLocalSocket::disconnected, this, [this] {
        setEventStreamConnected(false);
        if (available())
            m_reconnectTimer.start();
    });

    connect(&m_eventSocket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError error) {
        if (error == QLocalSocket::PeerClosedError)
            return;

        setEventStreamConnected(false);
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

void HyprlandIpcBridge::start()
{
    discoverInstance();
    if (!available())
        return;

    refreshAll();
    connectEventStream();
}

void HyprlandIpcBridge::refreshAll()
{
    scheduleRefresh(RefreshEverything);
}

void HyprlandIpcBridge::discoverInstance()
{
    const QString signature = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
    QString runtimeDirectory = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtimeDirectory.isEmpty())
        runtimeDirectory = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);

    if (signature.isEmpty() || runtimeDirectory.isEmpty()) {
        setAvailable(false);
        setLastError(QStringLiteral("Hyprland IPC environment is unavailable"));
        return;
    }

    const auto paths = HyprlandProtocol::socketPaths(runtimeDirectory, signature);
    if (paths.first.isEmpty() || paths.second.isEmpty()) {
        setAvailable(false);
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

    if (event.name.startsWith(QStringLiteral("openwindow"))
        || event.name.startsWith(QStringLiteral("closewindow"))
        || event.name.startsWith(QStringLiteral("movewindow"))
        || event.name.startsWith(QStringLiteral("activewindow"))
        || event.name.startsWith(QStringLiteral("windowtitle"))
        || event.name == QStringLiteral("fullscreen")
        || event.name == QStringLiteral("changefloatingmode")
        || event.name == QStringLiteral("pin")
        || event.name == QStringLiteral("minimized")) {
        scheduleRefresh(RefreshWindows);
        return;
    }

    if (event.name == QStringLiteral("configreloaded"))
        scheduleRefresh(RefreshEverything);
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

void HyprlandIpcBridge::requestJson(const QByteArray &request, JsonCallback callback)
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

    connect(timeout, &QTimer::timeout, this, [this, finish] {
        if (finish(true))
            setLastError(QStringLiteral("Hyprland IPC request timed out"));
    });

    connect(socket, &QLocalSocket::connected, this, [socket, request, timeout] {
        socket->write(request);
        socket->flush();
        timeout->start();
    });

    connect(socket, &QLocalSocket::readyRead, this,
            [this, socket, buffer, callback = std::move(callback), finish] {
        buffer->append(socket->readAll());

        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(*buffer, &parseError);
        if (parseError.error == QJsonParseError::UnterminatedObject
            || parseError.error == QJsonParseError::UnterminatedArray
            || parseError.error == QJsonParseError::IllegalValue) {
            return;
        }

        if (parseError.error != QJsonParseError::NoError) {
            if (finish(false))
                setLastError(QStringLiteral("Hyprland IPC returned invalid JSON: %1")
                                 .arg(parseError.errorString()));
            return;
        }

        if (finish(false)) {
            setLastError({});
            callback(*buffer);
        }
    });

    connect(socket, &QLocalSocket::errorOccurred, this,
            [this, socket, finish](QLocalSocket::LocalSocketError error) {
        if (error == QLocalSocket::PeerClosedError)
            return;

        if (finish(true))
            setLastError(QStringLiteral("Hyprland command socket: %1").arg(socket->errorString()));
    });

    socket->connectToServer(m_commandSocketPath, QIODevice::ReadWrite);
}
