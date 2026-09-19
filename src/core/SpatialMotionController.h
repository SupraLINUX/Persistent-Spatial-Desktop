#pragma once

#include <QObject>
#include <QPointF>
#include <QString>
#include <QVariantAnimation>

class SpatialLayout;
class SpatialState;

class SpatialMotionController final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QPointF offset READ offset NOTIFY offsetChanged)
    Q_PROPERTY(double offsetX READ offsetX NOTIFY offsetChanged)
    Q_PROPERTY(double offsetY READ offsetY NOTIFY offsetChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(QString targetSurface READ targetSurface NOTIFY targetSurfaceChanged)
    Q_PROPERTY(int durationMs READ durationMs WRITE setDurationMs NOTIFY durationMsChanged)

public:
    SpatialMotionController(SpatialState *state, SpatialLayout *layout, QObject *parent = nullptr);

    [[nodiscard]] QPointF offset() const;
    [[nodiscard]] double offsetX() const noexcept;
    [[nodiscard]] double offsetY() const noexcept;
    [[nodiscard]] bool running() const noexcept;
    [[nodiscard]] QString targetSurface() const;
    [[nodiscard]] int durationMs() const noexcept;

    void setDurationMs(int durationMs);

    Q_INVOKABLE bool navigate(const QString &destination);
    Q_INVOKABLE void center();
    Q_INVOKABLE void stop();

signals:
    void offsetChanged();
    void runningChanged();
    void targetSurfaceChanged();
    void durationMsChanged();
    void transitionStarted(const QString &destination);
    void transitionFinished(const QString &destination);

private:
    void setOffset(const QPointF &offset);
    void setTargetSurface(const QString &surface);
    void syncToCurrentSurface();

    SpatialState *m_state = nullptr;
    SpatialLayout *m_layout = nullptr;
    QVariantAnimation m_animation;
    QPointF m_offset;
    QString m_targetSurface = QStringLiteral("center");
    int m_durationMs = 500;
};
