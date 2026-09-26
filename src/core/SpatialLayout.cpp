#include "core/SpatialLayout.h"

#include <QtGlobal>

#include <algorithm>

SpatialLayout::SpatialLayout(QObject *parent)
    : QObject(parent)
{
}

QSizeF SpatialLayout::viewportSize() const
{
    return m_viewportSize;
}

void SpatialLayout::setViewportSize(const QSizeF &size)
{
    if (m_viewportSize == size)
        return;

    m_viewportSize = size;
    recompute();
    emit geometryChanged();
}

double SpatialLayout::gutter() const noexcept
{
    return m_gutter;
}

double SpatialLayout::leftWidth() const noexcept
{
    return m_leftWidth;
}

double SpatialLayout::rightWidth() const noexcept
{
    return m_rightWidth;
}

double SpatialLayout::topHeight() const noexcept
{
    return m_topHeight;
}

double SpatialLayout::centerWidth() const noexcept
{
    return std::max(0.0, m_viewportSize.width() - (m_gutter * 2.0));
}

double SpatialLayout::centerHeight() const noexcept
{
    return std::max(0.0, m_viewportSize.height() - (m_gutter * 2.0));
}

QPointF SpatialLayout::offsetForSurface(const QString &surface) const
{
    const QString normalized = surface.trimmed().toLower();

    if (normalized == QStringLiteral("left"))
        return {m_leftWidth - m_gutter, 0.0};

    if (normalized == QStringLiteral("right"))
        return {-(m_rightWidth - m_gutter), 0.0};

    if (normalized == QStringLiteral("top"))
        return {0.0, m_topHeight - m_gutter};

    if (normalized == QStringLiteral("dash"))
        return {0.0, -std::max(0.0, m_viewportSize.height() - (m_gutter * 3.0))};

    return {};
}

QMargins SpatialLayout::returnShieldMargins(const QString &surface) const
{
    const QString normalized = surface.trimmed().toLower();
    const int height = std::max(0, qRound(m_viewportSize.height()));
    const int gutterValue = std::max(0, qRound(m_gutter));

    if (normalized == QStringLiteral("left"))
        return {qRound(m_leftWidth), gutterValue, 0, gutterValue};

    if (normalized == QStringLiteral("right"))
        return {0, gutterValue, qRound(m_rightWidth), gutterValue};

    if (normalized == QStringLiteral("top"))
        return {gutterValue, qRound(m_topHeight), gutterValue, 0};

    if (normalized == QStringLiteral("dash")) {
        const int visibleCenter = std::min(height, gutterValue * 2);
        return {gutterValue, 0, gutterValue, std::max(0, height - visibleCenter)};
    }

    return {};
}

void SpatialLayout::recompute()
{
    const double smallerSide = std::min(m_viewportSize.width(), m_viewportSize.height());
    m_gutter = std::clamp(smallerSide * 0.012, 12.0, 18.0);
    m_leftWidth = std::clamp(m_viewportSize.width() * 0.24, 320.0, 460.0);
    m_rightWidth = std::clamp(m_viewportSize.width() * 0.26, 340.0, 500.0);
    m_topHeight = std::clamp(m_viewportSize.height() * 0.25, 220.0, 320.0);
}
