#pragma once

#include <QObject>
#include <QPointF>
#include <QSizeF>
#include <QString>

class SpatialLayout final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QSizeF viewportSize READ viewportSize WRITE setViewportSize NOTIFY geometryChanged)
    Q_PROPERTY(double gutter READ gutter NOTIFY geometryChanged)
    Q_PROPERTY(double leftWidth READ leftWidth NOTIFY geometryChanged)
    Q_PROPERTY(double rightWidth READ rightWidth NOTIFY geometryChanged)
    Q_PROPERTY(double topHeight READ topHeight NOTIFY geometryChanged)
    Q_PROPERTY(double centerWidth READ centerWidth NOTIFY geometryChanged)
    Q_PROPERTY(double centerHeight READ centerHeight NOTIFY geometryChanged)

public:
    explicit SpatialLayout(QObject *parent = nullptr);

    [[nodiscard]] QSizeF viewportSize() const;
    void setViewportSize(const QSizeF &size);

    [[nodiscard]] double gutter() const noexcept;
    [[nodiscard]] double leftWidth() const noexcept;
    [[nodiscard]] double rightWidth() const noexcept;
    [[nodiscard]] double topHeight() const noexcept;
    [[nodiscard]] double centerWidth() const noexcept;
    [[nodiscard]] double centerHeight() const noexcept;

    Q_INVOKABLE QPointF offsetForSurface(const QString &surface) const;

signals:
    void geometryChanged();

private:
    void recompute();

    QSizeF m_viewportSize;
    double m_gutter = 12.0;
    double m_leftWidth = 320.0;
    double m_rightWidth = 340.0;
    double m_topHeight = 220.0;
};
