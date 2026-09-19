#include "core/SpatialMotionController.h"

#include "core/SpatialLayout.h"
#include "core/SpatialState.h"

#include <QEasingCurve>
#include <QtGlobal>

#include <algorithm>
#include <cmath>

namespace {
constexpr double kGestureAxisLockDistance = 8.0;
constexpr double kGestureCommitProgress = 0.45;
constexpr double kGestureCommitVelocityPerSecond = 1.0;
}

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
    return m_gestureActive || m_animation.state() == QAbstractAnimation::Running;
}

bool SpatialMotionController::gestureActive() const noexcept
{
    return m_gestureActive;
}

double SpatialMotionController::gestureProgress() const noexcept
{
    return m_gestureProgress;
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

    if (m_gestureActive)
        finishGestureTracking();
    if (m_animation.state() == QAbstractAnimation::Running)
        m_animation.stop();

    setTargetSurface(normalized);

    const QPointF destinationOffset = m_layout->offsetForSurface(normalized);
    if (m_offset == destinationOffset) {
        m_state->navigate(normalized);
        emit transitionFinished(normalized);
        return true;
    }

    m_animation.setDuration(m_durationMs);
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

void SpatialMotionController::snapToCenter()
{
    if (m_animation.state() == QAbstractAnimation::Running)
        m_animation.stop();

    if (m_gestureActive)
        finishGestureTracking();

    setTargetSurface(QStringLiteral("center"));
    m_state->center();
    setOffset(QPointF{});
    emit transitionFinished(QStringLiteral("center"));
}

void SpatialMotionController::stop()
{
    if (m_gestureActive)
        finishGestureTracking();

    if (m_animation.state() == QAbstractAnimation::Running)
        m_animation.stop();
}

bool SpatialMotionController::beginGesture()
{
    if (m_state->currentSurface() != QStringLiteral("center"))
        return false;

    if (m_animation.state() == QAbstractAnimation::Running)
        m_animation.stop();

    m_gestureStartOffset = m_offset;
    m_gestureAccumulated = {};
    m_gestureDestination.clear();
    setGestureProgress(0.0);
    setGestureActive(true);
    return true;
}

bool SpatialMotionController::updateGesture(double deltaX, double deltaY)
{
    if (!m_gestureActive)
        return false;

    m_gestureAccumulated += QPointF(deltaX, deltaY);
    const QPointF candidate = m_gestureStartOffset + m_gestureAccumulated;

    if (m_gestureDestination.isEmpty()) {
        m_gestureDestination = gestureDestinationFor(candidate);
        if (m_gestureDestination.isEmpty())
            return true;

        setTargetSurface(m_gestureDestination);
        emit transitionStarted(m_gestureDestination);
    }

    const QPointF destination = m_layout->offsetForSurface(m_gestureDestination);
    const double progress = progressForOffset(candidate, destination);
    setGestureProgress(progress);
    setOffset(destination * progress);
    return true;
}

bool SpatialMotionController::endGesture(double velocityX, double velocityY, bool cancelled)
{
    if (!m_gestureActive)
        return false;

    const QString gestureDestination = m_gestureDestination;
    const QPointF destination = m_layout->offsetForSurface(gestureDestination);
    const QPointF velocity(velocityX, velocityY);

    bool commit = false;
    if (!cancelled && !gestureDestination.isEmpty()) {
        const double normalizedVelocity = normalizedVelocityToward(velocity, destination);
        commit = m_gestureProgress >= kGestureCommitProgress
            || normalizedVelocity >= kGestureCommitVelocityPerSecond;
    }

    const QString settleDestination = commit ? gestureDestination : QStringLiteral("center");
    const QPointF settleOffset = m_layout->offsetForSurface(settleDestination);

    setTargetSurface(settleDestination);

    m_animation.setDuration(m_durationMs);
    m_animation.setStartValue(m_offset);
    m_animation.setEndValue(settleOffset);
    m_animation.start();

    finishGestureTracking();
    return true;
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

void SpatialMotionController::setGestureProgress(double progress)
{
    const double clamped = std::clamp(progress, 0.0, 1.0);
    if (qFuzzyCompare(m_gestureProgress + 1.0, clamped + 1.0))
        return;

    m_gestureProgress = clamped;
    emit gestureProgressChanged();
}

void SpatialMotionController::setGestureActive(bool active)
{
    if (m_gestureActive == active)
        return;

    m_gestureActive = active;
    emit gestureActiveChanged();
    emit runningChanged();
}

void SpatialMotionController::syncToCurrentSurface()
{
    setOffset(m_layout->offsetForSurface(m_state->currentSurface()));
}

void SpatialMotionController::finishGestureTracking()
{
    m_gestureDestination.clear();
    m_gestureStartOffset = {};
    m_gestureAccumulated = {};
    setGestureProgress(0.0);
    setGestureActive(false);
}

QString SpatialMotionController::gestureDestinationFor(const QPointF &candidate) const
{
    const double absX = std::abs(candidate.x());
    const double absY = std::abs(candidate.y());

    if (std::max(absX, absY) < kGestureAxisLockDistance)
        return {};

    if (absX >= absY)
        return candidate.x() >= 0.0 ? QStringLiteral("left") : QStringLiteral("right");

    return candidate.y() >= 0.0 ? QStringLiteral("top") : QStringLiteral("dash");
}

double SpatialMotionController::progressForOffset(
    const QPointF &offset, const QPointF &destination) const
{
    if (!qFuzzyIsNull(destination.x())) {
        const double distance = std::abs(destination.x());
        const double signedOffset = offset.x() * (destination.x() >= 0.0 ? 1.0 : -1.0);
        return std::clamp(signedOffset / distance, 0.0, 1.0);
    }

    if (!qFuzzyIsNull(destination.y())) {
        const double distance = std::abs(destination.y());
        const double signedOffset = offset.y() * (destination.y() >= 0.0 ? 1.0 : -1.0);
        return std::clamp(signedOffset / distance, 0.0, 1.0);
    }

    return 0.0;
}

double SpatialMotionController::normalizedVelocityToward(
    const QPointF &velocity, const QPointF &destination) const
{
    if (!qFuzzyIsNull(destination.x())) {
        const double signedVelocity = velocity.x() * (destination.x() >= 0.0 ? 1.0 : -1.0);
        return signedVelocity / std::abs(destination.x());
    }

    if (!qFuzzyIsNull(destination.y())) {
        const double signedVelocity = velocity.y() * (destination.y() >= 0.0 ? 1.0 : -1.0);
        return signedVelocity / std::abs(destination.y());
    }

    return 0.0;
}
