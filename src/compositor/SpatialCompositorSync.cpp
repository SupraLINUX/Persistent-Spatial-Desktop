#include "compositor/SpatialCompositorSync.h"

#include "compositor/CompositorBridge.h"
#include "core/SpatialMotionController.h"

#include <QEventLoop>
#include <QTimer>
#include <QtGlobal>

#include <algorithm>
#include <utility>

SpatialCompositorSync::SpatialCompositorSync(
    SpatialMotionController *motion,
    CompositorBridge *bridge,
    QString monitorName,
    QObject *parent)
    : QObject(parent)
    , m_motion(motion)
    , m_bridge(bridge)
    , m_monitorName(std::move(monitorName))
{
    Q_ASSERT(m_motion);
    Q_ASSERT(m_bridge);

    connect(m_motion, &SpatialMotionController::offsetChanged,
            this, &SpatialCompositorSync::queueCurrentOffset);

    connect(m_bridge, &CompositorBridge::capabilitiesChanged,
            this, &SpatialCompositorSync::handleBridgeAvailabilityChanged);
    connect(m_bridge, &CompositorBridge::availableChanged,
            this, &SpatialCompositorSync::handleBridgeAvailabilityChanged);

    connect(m_bridge, &CompositorBridge::spatialTransformCommandFinished,
            this,
            [this](
                quint64 commandId,
                const QString &monitorName,
                bool success,
                const QString &message) {
        if (monitorName != m_monitorName || commandId != m_inFlightCommandId)
            return;

        const bool completedReset = m_inFlightReset;
        m_inFlightCommandId = 0;
        m_inFlightReset = false;

        if (success && completedReset)
            m_transformMayBeOffset = false;

        setLastError(success ? QString{} : message);
        dispatchPending();
        emitSettledIfIdle();
    });
}

bool SpatialCompositorSync::enabled() const noexcept
{
    return m_enabled;
}

void SpatialCompositorSync::setEnabled(bool enabled)
{
    if (m_enabled == enabled)
        return;

    m_enabled = enabled;
    emit enabledChanged();
    emit activeChanged();

    if (m_enabled) {
        m_resetRequested = false;
        queueCurrentOffset();
        return;
    }

    m_hasPending = false;

    if (m_transformMayBeOffset || m_inFlightCommandId != 0)
        m_resetRequested = true;

    dispatchPending();
    emitSettledIfIdle();
}

bool SpatialCompositorSync::active() const
{
    return m_enabled && m_bridge->spatialTransformAvailable();
}

bool SpatialCompositorSync::idle() const noexcept
{
    return m_inFlightCommandId == 0 && !m_hasPending && !m_resetRequested;
}

QString SpatialCompositorSync::monitorName() const
{
    return m_monitorName;
}

QString SpatialCompositorSync::lastError() const
{
    return m_lastError;
}

bool SpatialCompositorSync::shutdownAndReset(int timeoutMs)
{
    const int boundedTimeoutMs = std::max(0, timeoutMs);

    if (m_enabled)
        setEnabled(false);
    else if (m_transformMayBeOffset || m_inFlightCommandId != 0) {
        m_hasPending = false;
        m_resetRequested = true;
        dispatchPending();
    }

    if (idle())
        return !m_transformMayBeOffset && m_lastError.isEmpty();

    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);

    connect(this, &SpatialCompositorSync::settled, &loop, &QEventLoop::quit);
    connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);

    timeout.start(boundedTimeoutMs);
    loop.exec();

    return idle() && !m_transformMayBeOffset && m_lastError.isEmpty();
}

void SpatialCompositorSync::handleBridgeAvailabilityChanged()
{
    emit activeChanged();

    if (m_resetRequested) {
        dispatchPending();
        return;
    }

    if (active())
        queueCurrentOffset();
}

void SpatialCompositorSync::queueCurrentOffset()
{
    if (!active())
        return;

    m_pendingOffset = m_motion->offset();
    m_hasPending = true;
    dispatchPending();
}

void SpatialCompositorSync::dispatchPending()
{
    if (m_inFlightCommandId != 0)
        return;

    if (m_resetRequested) {
        if (!m_bridge->spatialTransformAvailable())
            return;

        m_resetRequested = false;
        m_inFlightReset = true;
        m_inFlightCommandId = m_bridge->resetSpatialTransformOffset(m_monitorName);
        return;
    }

    if (!active() || !m_hasPending)
        return;

    const QPointF offset = m_pendingOffset;
    m_hasPending = false;

    if (qFuzzyIsNull(offset.x()) && qFuzzyIsNull(offset.y())) {
        m_inFlightReset = true;
        m_inFlightCommandId = m_bridge->resetSpatialTransformOffset(m_monitorName);
        return;
    }

    m_inFlightReset = false;
    m_transformMayBeOffset = true;
    m_inFlightCommandId =
        m_bridge->setSpatialTransformOffset(m_monitorName, offset.x(), offset.y());
}

void SpatialCompositorSync::setLastError(const QString &error)
{
    if (m_lastError == error)
        return;

    m_lastError = error;
    emit lastErrorChanged();
}

void SpatialCompositorSync::emitSettledIfIdle()
{
    if (idle())
        emit settled();
}
