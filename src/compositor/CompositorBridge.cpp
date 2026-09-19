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
