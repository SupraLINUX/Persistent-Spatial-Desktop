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
    Q_PROPERTY(bool gestureActive READ gestureActive NOTIFY gestureActiveChanged)
    Q_PROPERTY(double gestureProgress READ gestureProgress NOTIFY gestureProgressChanged)
    Q_PROPERTY(QString targetSurface READ targetSurface NOTIFY targetSurfaceChanged)
    Q_PROPERTY(int durationMs READ durationMs WRITE setDurationMs NOTIFY durationMsChanged)

public:
    SpatialMotionController(SpatialState *state, SpatialLayout *layout, QObject *parent = nullptr);

    [[nodiscard]] QPointF offset() const;
    [[nodiscard]] double offsetX() const noexcept;
    [[nodiscard]] double offsetY() const noexcept;
    [[nodiscard]] bool running() const noexcept;
    [[nodiscard]] bool gestureActive() const noexcept;
    [[nodiscard]] double gestureProgress() const noexcept;
    [[nodiscard]] QString targetSurface() const;
    [[nodiscard]] int durationMs() const noexcept;

    void setDurationMs(int durationMs);

    Q_INVOKABLE bool navigate(const QString &destination);
    Q_INVOKABLE void center();
    Q_INVOKABLE void stop();

    // Gesture deltas are logical display units. Release velocities are logical
    // display units per second. The compositor/input backend owns device scaling.
    Q_INVOKABLE bool beginGesture();
    Q_INVOKABLE bool updateGesture(double deltaX, double deltaY);
    Q_INVOKABLE bool endGesture(double velocityX, double velocityY, bool cancelled = false);

signals:
    void offsetChanged();
    void runningChanged();
    void gestureActiveChanged();
    void gestureProgressChanged();
    void targetSurfaceChanged();
    void durationMsChanged();
    void transitionStarted(const QString &destination);
    void transitionFinished(const QString &destination);

private:
    void setOffset(const QPointF &offset);
    void setTargetSurface(const QString &surface);
    void setGestureProgress(double progress);
    void setGestureActive(bool active);
    void syncToCurrentSurface();
    void finishGestureTracking();
    [[nodiscard]] QString gestureDestinationFor(const QPointF &candidate) const;
    [[nodiscard]] double progressForOffset(const QPointF &offset, const QPointF &destination) const;
    [[nodiscard]] double normalizedVelocityToward(
        const QPointF &velocity, const QPointF &destination) const;

    SpatialState *m_state = nullptr;
    SpatialLayout *m_layout = nullptr;
    QVariantAnimation m_animation;
    QPointF m_offset;
    QPointF m_gestureStartOffset;
    QPointF m_gestureAccumulated;
    QString m_targetSurface = QStringLiteral("center");
    QString m_gestureDestination;
    int m_durationMs = 500;
    bool m_gestureActive = false;
    double m_gestureProgress = 0.0;
};
