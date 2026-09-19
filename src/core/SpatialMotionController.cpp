#include "core/SpatialMotionController.h"

#include "core/SpatialLayout.h"
#include "core/SpatialState.h"

#include <QEasingCurve>

#include <algorithm>

SpatialMotionController::SpatialMotionController(
    SpatialState *state, SpatialLayout *layout, QObject *parent)
    : QObject(parent)
    , m_state(state)
    , m_layout(layout)
{
    Q_ASSERT(m_state);
    Q_ASSERT(m_layout);

    QEasingCurve easing(QEasingCurve::BezierSpline);
    easing.addCubicBezierSegment(QPointF(0.22, 0.85), QPointF(0.26, 1.0), QPointF(1.0, 1.0));
    m_animation.setEasingCurve(easing);
    m_animation.setDuration(m_durationMs);

    connect(&m_animation, &QVariantAnimation::valueChanged, this, [this](const QVariant &value) {
        setOffset(value.toPointF());
    });

    connect(&m_animation, &QVariantAnimation::stateChanged, this,
            [this](QAbstractAnimation::State, QAbstractAnimation::State) {
        emit runningChanged();
    });

    connect(&m_animation, &QVariantAnimation::finished, this, [this] {
        m_state->navigate(m_targetSurface);
        setOffset(m_layout->offsetForSurface(m_targetSurface));
        emit transitionFinished(m_targetSurface);
    });

    connect(m_layout, &SpatialLayout::geometryChanged, this, [this] {
        if (!running())
            syncToCurrentSurface();
    });

    connect(m_state, &SpatialState::currentSurfaceChanged, this, [this] {
        if (!running()) {
            setTargetSurface(m_state->currentSurface());
            syncToCurrentSurface();
        }
    });
}

QPointF SpatialMotionController::offset() const
{
    return m_offset;
}

double SpatialMotionController::offsetX() const noexcept
{
    return m_offset.x();
}

double SpatialMotionController::offsetY() const noexcept
{
    return m_offset.y();
}

bool SpatialMotionController::running() const noexcept
{
    return m_animation.state() == QAbstractAnimation::Running;
}

QString SpatialMotionController::targetSurface() const
{
    return m_targetSurface;
}

int SpatialMotionController::durationMs() const noexcept
{
    return m_durationMs;
}

void SpatialMotionController::setDurationMs(int durationMs)
{
    const int clamped = std::clamp(durationMs, 0, 5000);
    if (m_durationMs == clamped)
        return;

    m_durationMs = clamped;
    m_animation.setDuration(m_durationMs);
    emit durationMsChanged();
}

bool SpatialMotionController::navigate(const QString &destination)
{
    const QString normalized = destination.trimmed().toLower();
    if (!m_state->destinations().contains(normalized))
        return false;

    if (running())
        m_animation.stop();

    setTargetSurface(normalized);

    const QPointF destinationOffset = m_layout->offsetForSurface(normalized);
    if (m_offset == destinationOffset) {
        m_state->navigate(normalized);
        emit transitionFinished(normalized);
        return true;
    }

    m_animation.setStartValue(m_offset);
    m_animation.setEndValue(destinationOffset);
    emit transitionStarted(normalized);
    m_animation.start();
    return true;
}

void SpatialMotionController::center()
{
    navigate(QStringLiteral("center"));
}

void SpatialMotionController::stop()
{
    if (!running())
        return;

    m_animation.stop();
}

void SpatialMotionController::setOffset(const QPointF &offset)
{
    if (m_offset == offset)
        return;

    m_offset = offset;
    emit offsetChanged();
}

void SpatialMotionController::setTargetSurface(const QString &surface)
{
    if (m_targetSurface == surface)
        return;

    m_targetSurface = surface;
    emit targetSurfaceChanged();
}

void SpatialMotionController::syncToCurrentSurface()
{
    setOffset(m_layout->offsetForSurface(m_state->currentSurface()));
}
