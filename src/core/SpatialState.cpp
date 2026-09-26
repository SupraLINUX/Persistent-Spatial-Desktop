#include "core/SpatialState.h"

SpatialState::SpatialState(QObject *parent)
    : QObject(parent)
{
}

QString SpatialState::currentSurface() const
{
    return m_currentSurface;
}

QStringList SpatialState::destinations() const
{
    return {
        QStringLiteral("center"),
        QStringLiteral("left"),
        QStringLiteral("right"),
        QStringLiteral("top"),
        QStringLiteral("dash"),
    };
}

bool SpatialState::navigate(const QString &destination)
{
    const QString normalized = destination.trimmed().toLower();
    if (!destinations().contains(normalized)) {
        return false;
    }

    if (normalized == m_currentSurface) {
        return true;
    }

    m_currentSurface = normalized;
    emit currentSurfaceChanged();
    return true;
}

void SpatialState::center()
{
    navigate(QStringLiteral("center"));
}
