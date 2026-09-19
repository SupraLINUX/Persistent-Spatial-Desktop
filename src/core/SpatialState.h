#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

class SpatialState final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString currentSurface READ currentSurface NOTIFY currentSurfaceChanged)
    Q_PROPERTY(QStringList destinations READ destinations CONSTANT)

public:
    explicit SpatialState(QObject *parent = nullptr);

    [[nodiscard]] QString currentSurface() const;
    [[nodiscard]] QStringList destinations() const;

    Q_INVOKABLE bool navigate(const QString &destination);
    Q_INVOKABLE void center();

signals:
    void currentSurfaceChanged();

private:
    QString m_currentSurface = QStringLiteral("center");
};
