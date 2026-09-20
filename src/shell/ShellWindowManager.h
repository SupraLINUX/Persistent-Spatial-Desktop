#pragma once

#include <QObject>
#include <QHash>
#include <QPointer>

class DesignTokens;
class HyprlandIpcBridge;
class QQmlApplicationEngine;
class QQmlContext;
class QQuickWindow;
class QScreen;
class SpatialCompositorSync;
class SpatialLayout;
class SpatialMotionController;
class SpatialState;

class ShellWindowManager final : public QObject
{
    Q_OBJECT

public:
    ShellWindowManager(
        QQmlApplicationEngine *engine,
        DesignTokens *designTokens,
        HyprlandIpcBridge *compositorBridge,
        QObject *parent = nullptr);

    void start();
    [[nodiscard]] int windowCount() const noexcept;
    bool shutdownCompositorSync(int timeoutMs = 1500);

private:
    struct Instance {
        QPointer<QScreen> screen;
        QPointer<QQmlContext> context;
        QPointer<QQuickWindow> window;
        QPointer<QQuickWindow> returnShield;
        QPointer<SpatialState> state;
        QPointer<SpatialLayout> layout;
        QPointer<SpatialMotionController> motion;
        QPointer<SpatialCompositorSync> compositorSync;
        bool fullscreenSuppressed = false;
        bool fullscreenStateInitialized = false;
    };

    void createForScreen(QScreen *screen);
    void destroyForScreen(QScreen *screen);
    bool createShellWindow(Instance *instance);
    void destroyShellWindow(Instance *instance);
    void configureLayerSurface(Instance *instance);
    void configureReturnShield(Instance *instance);
    void updateReturnShield(Instance *instance);
    void updateFullscreenState(Instance *instance);
    void updateAllFullscreenStates();
    [[nodiscard]] Instance *instanceForMonitorName(const QString &monitorName) const;

    QQmlApplicationEngine *m_engine = nullptr;
    DesignTokens *m_designTokens = nullptr;
    HyprlandIpcBridge *m_compositorBridge = nullptr;
    QHash<QScreen *, Instance *> m_instances;
};
