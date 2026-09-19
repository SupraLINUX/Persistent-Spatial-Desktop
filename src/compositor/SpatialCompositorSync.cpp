#include "compositor/SpatialCompositorSync.h"

#include "compositor/HyprlandIpcBridge.h"
#include "core/SpatialMotionController.h"

#include <QtGlobal>

#include <utility>

SpatialCompositorSync::SpatialCompositorSync(
    SpatialMotionController *motion,
    HyprlandIpcBridge *bridge,
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

    connect(m_bridge, &CompositorBridge::capabilitiesChanged, this, [this] {
        emit activeChanged();
        if (active())
            queueCurrentOffset();
    });

    connect(m_bridge, &HyprlandIpcBridge::experimentalSpatialCommandFinished,
            this,
            [this](const QString &monitorName, bool success, const QString &message) {
        if (monitorName != m_monitorName)
            return;

        m_inFlight = false;
        setLastError(success ? QString{} : message);
        dispatchPending();
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

    const bool wasActive = active();
    m_enabled = enabled;
    emit enabledChanged();
    emit activeChanged();

    if (m_enabled) {
        queueCurrentOffset();
        return;
    }

    m_hasPending = false;
    if (wasActive)
        m_bridge->resetExperimentalSpatialOffset(m_monitorName);
}

bool SpatialCompositorSync::active() const
{
    if (!m_enabled || !m_bridge->available())
        return false;

    const QVariantMap capabilities = m_bridge->capabilities();
    return capabilities.value(QStringLiteral("spatialRenderOffsetExperimental")).toBool()
        && capabilities.value(QStringLiteral("monitorTargeting")).toBool();
}

QString SpatialCompositorSync::monitorName() const
{
    return m_monitorName;
}

QString SpatialCompositorSync::lastError() const
{
    return m_lastError;
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
    if (!active() || m_inFlight || !m_hasPending)
        return;

    const QPointF offset = m_pendingOffset;
    m_hasPending = false;
    m_inFlight = true;

    if (qFuzzyIsNull(offset.x()) && qFuzzyIsNull(offset.y()))
        m_bridge->resetExperimentalSpatialOffset(m_monitorName);
    else
        m_bridge->setExperimentalSpatialOffset(m_monitorName, offset.x(), offset.y());
}

void SpatialCompositorSync::setLastError(const QString &error)
{
    if (m_lastError == error)
        return;

    m_lastError = error;
    emit lastErrorChanged();
}
