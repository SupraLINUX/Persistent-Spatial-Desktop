#include "compositor/CompositorBridge.h"

#include <utility>

CompositorBridge::CompositorBridge(QObject *parent)
    : QObject(parent)
{
}

bool CompositorBridge::available() const noexcept
{
    return m_available;
}

bool CompositorBridge::eventStreamConnected() const noexcept
{
    return m_eventStreamConnected;
}

QString CompositorBridge::lastError() const
{
    return m_lastError;
}

QVariantMap CompositorBridge::capabilities() const
{
    return m_capabilities;
}

QVariantList CompositorBridge::monitors() const
{
    return m_monitors;
}

QVariantList CompositorBridge::workspaces() const
{
    return m_workspaces;
}

QVariantList CompositorBridge::windows() const
{
    return m_windows;
}

bool CompositorBridge::monitorHasFullscreenWindow(const QString &monitorName) const
{
    QVariant monitorId;
    QVariant activeWorkspaceId;

    for (const QVariant &value : m_monitors) {
        const QVariantMap monitor = value.toMap();
        if (monitor.value(QStringLiteral("name")).toString() != monitorName)
            continue;

        monitorId = monitor.value(QStringLiteral("id"));
        activeWorkspaceId = monitor.value(QStringLiteral("activeWorkspace"))
                                .toMap()
                                .value(QStringLiteral("id"));
        break;
    }

    if (!monitorId.isValid() || !activeWorkspaceId.isValid())
        return false;

    const qlonglong wantedMonitor = monitorId.toLongLong();
    const qlonglong wantedWorkspace = activeWorkspaceId.toLongLong();

    for (const QVariant &value : m_windows) {
        const QVariantMap window = value.toMap();
        if (!window.value(QStringLiteral("mapped"), true).toBool())
            continue;
        if (window.value(QStringLiteral("fullscreen")).toInt() == 0)
            continue;
        if (window.value(QStringLiteral("monitorId")).toLongLong() != wantedMonitor)
            continue;

        const qlonglong workspaceId = window.value(QStringLiteral("workspace"))
                                          .toMap()
                                          .value(QStringLiteral("id"))
                                          .toLongLong();
        if (workspaceId == wantedWorkspace)
            return true;
    }

    return false;
}

quint64 CompositorBridge::allocateSpatialTransformCommandId()
{
    const quint64 commandId = m_nextSpatialTransformCommandId++;
    if (m_nextSpatialTransformCommandId == 0)
        m_nextSpatialTransformCommandId = 1;
    return commandId;
}

void CompositorBridge::setAvailable(bool available)
{
    if (m_available == available)
        return;

    m_available = available;
    emit availableChanged();
}

void CompositorBridge::setEventStreamConnected(bool connected)
{
    if (m_eventStreamConnected == connected)
        return;

    m_eventStreamConnected = connected;
    emit eventStreamConnectedChanged();
}

void CompositorBridge::setLastError(const QString &error)
{
    if (m_lastError == error)
        return;

    m_lastError = error;
    emit lastErrorChanged();
}

void CompositorBridge::setCapabilities(QVariantMap capabilities)
{
    if (m_capabilities == capabilities)
        return;

    m_capabilities = std::move(capabilities);
    emit capabilitiesChanged();
}

void CompositorBridge::setMonitors(QVariantList monitors)
{
    if (m_monitors == monitors)
        return;

    m_monitors = std::move(monitors);
    emit monitorsChanged();
}

void CompositorBridge::setWorkspaces(QVariantList workspaces)
{
    if (m_workspaces == workspaces)
        return;

    m_workspaces = std::move(workspaces);
    emit workspacesChanged();
}

void CompositorBridge::setWindows(QVariantList windows)
{
    if (m_windows == windows)
        return;

    m_windows = std::move(windows);
    emit windowsChanged();
}
