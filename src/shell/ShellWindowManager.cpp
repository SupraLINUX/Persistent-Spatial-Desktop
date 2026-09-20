#include "shell/ShellWindowManager.h"

#include "compositor/HyprlandIpcBridge.h"
#include "compositor/SpatialCompositorSync.h"
#include "core/DesignTokens.h"
#include "core/SpatialLayout.h"
#include "core/SpatialMotionController.h"
#include "core/SpatialState.h"

#include <LayerShellQt/window.h>

#include <QElapsedTimer>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QMargins>
#include <QQuickWindow>
#include <QScreen>
#include <QUrl>

#include <algorithm>

ShellWindowManager::ShellWindowManager(
    QQmlApplicationEngine *engine,
    DesignTokens *designTokens,
    HyprlandIpcBridge *compositorBridge,
    QObject *parent)
    : QObject(parent)
    , m_engine(engine)
    , m_designTokens(designTokens)
    , m_compositorBridge(compositorBridge)
{
    Q_ASSERT(m_engine);
    Q_ASSERT(m_designTokens);
    Q_ASSERT(m_compositorBridge);

    connect(m_compositorBridge, &HyprlandIpcBridge::experimentalSpatialGestureBegin,
            this, [this](const QString &monitorName) {
        Instance *instance = instanceForMonitorName(monitorName);
        if (!instance || !instance->compositorSync || !instance->compositorSync->active())
            return;

        instance->motion->beginGesture();
    });

    connect(m_compositorBridge, &HyprlandIpcBridge::experimentalSpatialGestureUpdate,
            this, [this](const QString &monitorName, double deltaX, double deltaY) {
        Instance *instance = instanceForMonitorName(monitorName);
        if (!instance || !instance->compositorSync || !instance->compositorSync->active())
            return;

        instance->motion->updateGesture(deltaX, deltaY);
    });

    connect(m_compositorBridge, &HyprlandIpcBridge::experimentalSpatialGestureEnd,
            this, [this](const QString &monitorName, double velocityX, double velocityY, bool cancelled) {
        Instance *instance = instanceForMonitorName(monitorName);
        if (!instance || !instance->compositorSync || !instance->compositorSync->active())
            return;

        instance->motion->endGesture(velocityX, velocityY, cancelled);
    });

    connect(m_compositorBridge, &CompositorBridge::monitorsChanged,
            this, &ShellWindowManager::updateAllFullscreenStates);
    connect(m_compositorBridge, &CompositorBridge::windowsChanged,
            this, &ShellWindowManager::updateAllFullscreenStates);
}

void ShellWindowManager::start()
{
    connect(qGuiApp, &QGuiApplication::screenAdded,
            this, &ShellWindowManager::createForScreen);
    connect(qGuiApp, &QGuiApplication::screenRemoved,
            this, &ShellWindowManager::destroyForScreen);

    for (QScreen *screen : QGuiApplication::screens())
        createForScreen(screen);
}

int ShellWindowManager::windowCount() const noexcept
{
    return m_instances.size();
}

bool ShellWindowManager::shutdownCompositorSync(int timeoutMs)
{
    const int boundedTimeoutMs = std::max(0, timeoutMs);

    for (Instance *instance : m_instances) {
        if (instance && instance->compositorSync)
            instance->compositorSync->setEnabled(false);
    }

    QElapsedTimer elapsed;
    elapsed.start();

    bool success = true;
    for (Instance *instance : m_instances) {
        if (!instance || !instance->compositorSync)
            continue;

        const int remainingMs =
            std::max(0, boundedTimeoutMs - static_cast<int>(elapsed.elapsed()));
        if (instance->compositorSync->shutdownAndReset(remainingMs))
            continue;

        success = false;
        qWarning().noquote()
            << "PSD failed to confirm final compositor reset for"
            << instance->compositorSync->monitorName()
            << instance->compositorSync->lastError();
    }

    return success;
}

bool ShellWindowManager::createShellWindow(Instance *instance)
{
    if (!instance || !instance->screen || !instance->context)
        return false;

    if (instance->window)
        return true;

    QQmlComponent component(m_engine, QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (component.status() != QQmlComponent::Ready) {
        qCritical().noquote()
            << "PSD failed to load shell component for"
            << instance->screen->name()
            << component.errorString();
        return false;
    }

    QObject *object = component.create(instance->context);
    auto *window = qobject_cast<QQuickWindow *>(object);
    if (!window) {
        qCritical().noquote()
            << "PSD shell root is not a QQuickWindow for"
            << instance->screen->name();
        delete object;
        return false;
    }

    instance->window = window;
    instance->window->setScreen(instance->screen);
    configureLayerSurface(instance);
    return true;
}

void ShellWindowManager::destroyShellWindow(Instance *instance)
{
    if (!instance || !instance->window)
        return;

    QQuickWindow *window = instance->window;
    instance->window = nullptr;

    window->close();
    delete window;
}

bool ShellWindowManager::createGutterWindows(Instance *instance)
{
    if (!instance || !instance->screen || !instance->context)
        return false;

    static const QStringList destinations{
        QStringLiteral("left"),
        QStringLiteral("right"),
        QStringLiteral("top"),
        QStringLiteral("dash"),
    };

    if (instance->gutterWindows.size() == destinations.size())
        return true;

    destroyGutterWindows(instance);

    QQmlComponent component(m_engine, QUrl(QStringLiteral("qrc:/qml/GutterInput.qml")));
    if (component.status() != QQmlComponent::Ready) {
        qCritical().noquote()
            << "PSD failed to load gutter component for"
            << instance->screen->name()
            << component.errorString();
        return false;
    }

    for (const QString &destination : destinations) {
        QObject *object = component.create(instance->context);
        auto *window = qobject_cast<QQuickWindow *>(object);
        if (!window) {
            qCritical().noquote()
                << "PSD gutter root is not a QQuickWindow for"
                << instance->screen->name()
                << destination;
            delete object;
            destroyGutterWindows(instance);
            return false;
        }

        window->setProperty("destination", destination);
        window->setScreen(instance->screen);
        instance->gutterWindows.insert(destination, window);
        configureGutterSurface(instance, window, destination);
    }

    updateGutterWindows(instance);
    return true;
}

void ShellWindowManager::destroyGutterWindows(Instance *instance)
{
    if (!instance)
        return;

    const auto windows = instance->gutterWindows.values();
    instance->gutterWindows.clear();

    for (QQuickWindow *window : windows) {
        if (!window)
            continue;

        window->close();
        delete window;
    }
}

void ShellWindowManager::createForScreen(QScreen *screen)
{
    if (!screen || m_instances.contains(screen))
        return;

    auto *instance = new Instance;
    instance->screen = screen;

    instance->state = new SpatialState(this);
    instance->layout = new SpatialLayout(this);
    instance->motion = new SpatialMotionController(instance->state, instance->layout, this);
    instance->motion->setDurationMs(
        m_designTokens->value(QStringLiteral("motion.durationMs.spatial")).toInt());

    instance->compositorSync = new SpatialCompositorSync(
        instance->motion, m_compositorBridge, screen->name(), this);
    instance->compositorSync->setEnabled(
        qEnvironmentVariableIntValue("PSD_EXPERIMENTAL_HYPRLAND_SYNC") == 1);

    instance->context = new QQmlContext(m_engine->rootContext(), this);
    instance->context->setContextProperty(QStringLiteral("SpatialState"), instance->state);
    instance->context->setContextProperty(QStringLiteral("SpatialLayout"), instance->layout);
    instance->context->setContextProperty(QStringLiteral("SpatialMotion"), instance->motion);
    instance->context->setContextProperty(QStringLiteral("PsdCompositorSync"), instance->compositorSync);
    instance->context->setContextProperty(QStringLiteral("PsdScreenName"), screen->name());

    if (!createShellWindow(instance) || !createGutterWindows(instance)) {
        destroyGutterWindows(instance);
        destroyShellWindow(instance);
        instance->context->deleteLater();
        instance->compositorSync->deleteLater();
        instance->motion->deleteLater();
        instance->layout->deleteLater();
        instance->state->deleteLater();
        delete instance;
        return;
    }

    QQmlComponent shieldComponent(m_engine, QUrl(QStringLiteral("qrc:/qml/ReturnShield.qml")));
    if (shieldComponent.status() != QQmlComponent::Ready) {
        qCritical().noquote() << "PSD failed to load return shield for" << screen->name()
                              << shieldComponent.errorString();
        destroyGutterWindows(instance);
        destroyShellWindow(instance);
        delete instance;
        return;
    }

    QObject *shieldObject = shieldComponent.create(instance->context);
    instance->returnShield = qobject_cast<QQuickWindow *>(shieldObject);
    if (!instance->returnShield) {
        qCritical().noquote() << "PSD return shield root is not a QQuickWindow for" << screen->name();
        delete shieldObject;
        destroyGutterWindows(instance);
        destroyShellWindow(instance);
        delete instance;
        return;
    }

    instance->returnShield->setScreen(screen);
    configureReturnShield(instance);

    connect(instance->motion, &SpatialMotionController::runningChanged,
            this, [this, instance] {
                updateGutterWindows(instance);
                updateReturnShield(instance);
            });
    connect(instance->motion, &SpatialMotionController::transitionStarted,
            this, [this, instance](const QString &) {
                updateGutterWindows(instance);
                updateReturnShield(instance);
            });
    connect(instance->motion, &SpatialMotionController::transitionFinished,
            this, [this, instance](const QString &) {
                updateGutterWindows(instance);
                updateReturnShield(instance);
            });
    connect(instance->state, &SpatialState::currentSurfaceChanged,
            this, [this, instance] {
                updateGutterWindows(instance);
                updateReturnShield(instance);
            });
    connect(instance->layout, &SpatialLayout::geometryChanged,
            this, [this, instance] {
                updateGutterWindows(instance);
                updateReturnShield(instance);
            });

    m_instances.insert(screen, instance);
    updateFullscreenState(instance);
    updateGutterWindows(instance);
    updateReturnShield(instance);
}

void ShellWindowManager::destroyForScreen(QScreen *screen)
{
    Instance *instance = m_instances.take(screen);
    if (!instance)
        return;

    if (instance->compositorSync
        && !instance->compositorSync->shutdownAndReset(250)) {
        qWarning().noquote()
            << "PSD could not confirm compositor reset while removing"
            << instance->compositorSync->monitorName()
            << instance->compositorSync->lastError();
    }

    if (instance->returnShield) {
        instance->returnShield->close();
        instance->returnShield->deleteLater();
    }

    destroyGutterWindows(instance);
    destroyShellWindow(instance);

    if (instance->context)
        instance->context->deleteLater();
    if (instance->compositorSync)
        instance->compositorSync->deleteLater();
    if (instance->motion)
        instance->motion->deleteLater();
    if (instance->layout)
        instance->layout->deleteLater();
    if (instance->state)
        instance->state->deleteLater();

    delete instance;
}

void ShellWindowManager::configureLayerSurface(Instance *instance)
{
    auto *layerWindow = LayerShellQt::Window::get(instance->window);
    if (!layerWindow) {
        qCritical().noquote() << "PSD failed to create layer surface for"
                              << instance->screen->name();
        return;
    }

    layerWindow->setScope(QStringLiteral("psd-shell:%1").arg(instance->screen->name()));
    layerWindow->setScreen(instance->screen);
    layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
    LayerShellQt::Window::Anchors anchors;
    anchors |= LayerShellQt::Window::AnchorTop;
    anchors |= LayerShellQt::Window::AnchorBottom;
    anchors |= LayerShellQt::Window::AnchorLeft;
    anchors |= LayerShellQt::Window::AnchorRight;
    layerWindow->setAnchors(anchors);
    layerWindow->setExclusiveZone(-1);
    layerWindow->setKeyboardInteractivity(
        LayerShellQt::Window::KeyboardInteractivityOnDemand);
    layerWindow->setActivateOnShow(false);
}

void ShellWindowManager::configureGutterSurface(
    Instance *instance,
    QQuickWindow *window,
    const QString &destination)
{
    if (!instance || !instance->screen || !window)
        return;

    auto *layerWindow = LayerShellQt::Window::get(window);
    if (!layerWindow) {
        qCritical().noquote()
            << "PSD failed to create gutter layer surface for"
            << instance->screen->name()
            << destination;
        return;
    }

    layerWindow->setScope(
        QStringLiteral("psd-gutter:%1:%2")
            .arg(instance->screen->name(), destination));
    layerWindow->setScreen(instance->screen);
    layerWindow->setLayer(LayerShellQt::Window::LayerTop);

    LayerShellQt::Window::Anchors anchors;
    if (destination == QStringLiteral("left")) {
        anchors |= LayerShellQt::Window::AnchorTop;
        anchors |= LayerShellQt::Window::AnchorBottom;
        anchors |= LayerShellQt::Window::AnchorLeft;
    } else if (destination == QStringLiteral("right")) {
        anchors |= LayerShellQt::Window::AnchorTop;
        anchors |= LayerShellQt::Window::AnchorBottom;
        anchors |= LayerShellQt::Window::AnchorRight;
    } else if (destination == QStringLiteral("top")) {
        anchors |= LayerShellQt::Window::AnchorTop;
        anchors |= LayerShellQt::Window::AnchorLeft;
        anchors |= LayerShellQt::Window::AnchorRight;
    } else {
        anchors |= LayerShellQt::Window::AnchorBottom;
        anchors |= LayerShellQt::Window::AnchorLeft;
        anchors |= LayerShellQt::Window::AnchorRight;
    }

    layerWindow->setAnchors(anchors);
    layerWindow->setExclusiveZone(-1);
    layerWindow->setKeyboardInteractivity(
        LayerShellQt::Window::KeyboardInteractivityNone);
    layerWindow->setActivateOnShow(false);
}

void ShellWindowManager::updateGutterWindows(Instance *instance)
{
    if (!instance || !instance->layout || !instance->motion || !instance->state)
        return;

    const int gutter = std::max(1, qRound(instance->layout->gutter()));
    const bool shouldShow =
        !instance->fullscreenSuppressed
        && instance->state->currentSurface() == QStringLiteral("center")
        && instance->motion->targetSurface() == QStringLiteral("center")
        && !instance->motion->running();

    for (auto it = instance->gutterWindows.begin();
         it != instance->gutterWindows.end();
         ++it) {
        QQuickWindow *window = it.value();
        if (!window)
            continue;

        auto *layerWindow = LayerShellQt::Window::get(window);
        if (!layerWindow)
            continue;

        const QString &destination = it.key();
        if (destination == QStringLiteral("left")
            || destination == QStringLiteral("right")) {
            layerWindow->setDesiredSize(QSize(gutter, 0));
            layerWindow->setMargins(QMargins(0, gutter, 0, gutter));
        } else {
            layerWindow->setDesiredSize(QSize(0, gutter));
            layerWindow->setMargins(QMargins(gutter, 0, gutter, 0));
        }

        if (shouldShow) {
            if (!window->isVisible())
                window->show();
        } else if (window->isVisible()) {
            window->hide();
        }
    }
}

void ShellWindowManager::configureReturnShield(Instance *instance)
{
    auto *layerWindow = LayerShellQt::Window::get(instance->returnShield);
    if (!layerWindow) {
        qCritical().noquote() << "PSD failed to create return shield layer surface for"
                              << instance->screen->name();
        return;
    }

    layerWindow->setScope(QStringLiteral("psd-return-shield:%1").arg(instance->screen->name()));
    layerWindow->setScreen(instance->screen);
    layerWindow->setLayer(LayerShellQt::Window::LayerTop);

    LayerShellQt::Window::Anchors anchors;
    anchors |= LayerShellQt::Window::AnchorTop;
    anchors |= LayerShellQt::Window::AnchorBottom;
    anchors |= LayerShellQt::Window::AnchorLeft;
    anchors |= LayerShellQt::Window::AnchorRight;
    layerWindow->setAnchors(anchors);
    layerWindow->setExclusiveZone(-1);
    layerWindow->setKeyboardInteractivity(
        LayerShellQt::Window::KeyboardInteractivityNone);
    layerWindow->setActivateOnShow(false);
}

void ShellWindowManager::updateReturnShield(Instance *instance)
{
    if (!instance || !instance->returnShield || !instance->layout || !instance->motion || !instance->state)
        return;

    auto *layerWindow = LayerShellQt::Window::get(instance->returnShield);
    if (!layerWindow)
        return;

    if (instance->fullscreenSuppressed) {
        instance->returnShield->hide();
        return;
    }

    if (instance->motion->running()) {
        layerWindow->setMargins(QMargins{});
        if (!instance->returnShield->isVisible())
            instance->returnShield->show();
        return;
    }

    const QString surface = instance->state->currentSurface();
    if (surface == QStringLiteral("center")) {
        instance->returnShield->hide();
        return;
    }

    const QSizeF viewport = instance->layout->viewportSize();
    const int width = std::max(0, qRound(viewport.width()));
    const int height = std::max(0, qRound(viewport.height()));
    const QMargins margins = instance->layout->returnShieldMargins(surface);

    if (width <= margins.left() + margins.right()
        || height <= margins.top() + margins.bottom()) {
        instance->returnShield->hide();
        return;
    }

    layerWindow->setMargins(margins);
    if (!instance->returnShield->isVisible())
        instance->returnShield->show();
}

ShellWindowManager::Instance *ShellWindowManager::instanceForMonitorName(const QString &monitorName) const
{
    for (Instance *instance : m_instances) {
        if (instance && instance->screen && instance->screen->name() == monitorName)
            return instance;
    }

    return nullptr;
}

void ShellWindowManager::updateFullscreenState(Instance *instance)
{
    if (!instance || !instance->screen || !instance->context
        || !instance->returnShield || !instance->motion)
        return;

    const bool fullscreen =
        m_compositorBridge->monitorHasFullscreenWindow(instance->screen->name());

    if (instance->fullscreenStateInitialized
        && instance->fullscreenSuppressed == fullscreen
        && (fullscreen
            || (instance->window && instance->gutterWindows.size() == 4)))
        return;

    instance->fullscreenStateInitialized = true;
    instance->fullscreenSuppressed = fullscreen;

    if (fullscreen) {
        instance->returnShield->hide();
        instance->motion->snapToCenter();

        // A Qt Wayland window is reset when it is unmapped. Reusing the same
        // QQuickWindow after fullscreen proved insufficient for reliable
        // pointer/hover delivery through LayerShellQt. Keep the monitor-local
        // PSD state/controllers alive, but destroy the native shell window so
        // fullscreen owns the output with no PSD layer surface remaining.
        destroyGutterWindows(instance);
        destroyShellWindow(instance);
        return;
    }

    // Recreate a fresh QWaylandWindow + layer-shell surface after fullscreen.
    // This preserves SpatialState/Layout/Motion/Sync while rebuilding the
    // input-capable shell surface from the same QML context.
    if ((!instance->window && !createShellWindow(instance))
        || !createGutterWindows(instance)) {
        destroyGutterWindows(instance);
        destroyShellWindow(instance);
        instance->fullscreenStateInitialized = false;
        qCritical().noquote()
            << "PSD failed to recreate shell presentation after fullscreen for"
            << instance->screen->name();
        return;
    }

    if (!instance->window->isVisible())
        instance->window->show();

    updateGutterWindows(instance);
    updateReturnShield(instance);
}

void ShellWindowManager::updateAllFullscreenStates()
{
    for (Instance *instance : m_instances)
        updateFullscreenState(instance);
}
