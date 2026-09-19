#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

class CompositorBridge : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString backendName READ backendName CONSTANT)
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(bool eventStreamConnected READ eventStreamConnected NOTIFY eventStreamConnectedChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(QVariantList monitors READ monitors NOTIFY monitorsChanged)
    Q_PROPERTY(QVariantList workspaces READ workspaces NOTIFY workspacesChanged)
    Q_PROPERTY(QVariantList windows READ windows NOTIFY windowsChanged)

public:
    explicit CompositorBridge(QObject *parent = nullptr);
    ~CompositorBridge() override = default;

    [[nodiscard]] virtual QString backendName() const = 0;
    [[nodiscard]] bool available() const noexcept;
    [[nodiscard]] bool eventStreamConnected() const noexcept;
    [[nodiscard]] QString lastError() const;
    [[nodiscard]] QVariantList monitors() const;
    [[nodiscard]] QVariantList workspaces() const;
    [[nodiscard]] QVariantList windows() const;

    virtual void start() = 0;
    Q_INVOKABLE virtual void refreshAll() = 0;

signals:
    void availableChanged();
    void eventStreamConnectedChanged();
    void lastErrorChanged();
    void monitorsChanged();
    void workspacesChanged();
    void windowsChanged();
    void compositorEvent(const QString &name, const QString &payload);

protected:
    void setAvailable(bool available);
    void setEventStreamConnected(bool connected);
    void setLastError(const QString &error);
    void setMonitors(QVariantList monitors);
    void setWorkspaces(QVariantList workspaces);
    void setWindows(QVariantList windows);

private:
    bool m_available = false;
    bool m_eventStreamConnected = false;
    QString m_lastError;
    QVariantList m_monitors;
    QVariantList m_workspaces;
    QVariantList m_windows;
};
