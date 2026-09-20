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

    QQmlComponent component(m_engine, QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (component.status() != QQmlComponent::Ready) {
        qCritical().noquote() << "PSD failed to load shell component for" << screen->name()
                              << component.errorString();
        delete instance;
        return;
    }

    QObject *object = component.create(instance->context);
    instance->window = qobject_cast<QQuickWindow *>(object);
    if (!instance->window) {
        qCritical().noquote() << "PSD shell root is not a QQuickWindow for" << screen->name();
        delete object;
        delete instance;
        return;
    }

    instance->window->setScreen(screen);
    configureLayerSurface(instance);

    QQmlComponent shieldComponent(m_engine, QUrl(QStringLiteral("qrc:/qml/ReturnShield.qml")));
    if (shieldComponent.status() != QQmlComponent::Ready) {
        qCritical().noquote() << "PSD failed to load return shield for" << screen->name()
                              << shieldComponent.errorString();
        instance->window->deleteLater();
        delete instance;
        return;
    }

    QObject *shieldObject = shieldComponent.create(instance->context);
    instance->returnShield = qobject_cast<QQuickWindow *>(shieldObject);
    if (!instance->returnShield) {
        qCritical().noquote() << "PSD return shield root is not a QQuickWindow for" << screen->name();
        delete shieldObject;
        instance->window->deleteLater();
        delete instance;
        return;
    }

    instance->returnShield->setScreen(screen);
    configureReturnShield(instance);

    connect(instance->motion, &SpatialMotionController::runningChanged,
            this, [this, instance] { updateReturnShield(instance); });
    connect(instance->motion, &SpatialMotionController::transitionStarted,
            this, [this, instance](const QString &) { updateReturnShield(instance); });
    connect(instance->motion, &SpatialMotionController::transitionFinished,
            this, [this, instance](const QString &) { updateReturnShield(instance); });
    connect(instance->state, &SpatialState::currentSurfaceChanged,
            this, [this, instance] { updateReturnShield(instance); });
    connect(instance->layout, &SpatialLayout::geometryChanged,
            this, [this, instance] { updateReturnShield(instance); });

    m_instances.insert(screen, instance);
    updateFullscreenState(instance);
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

    if (instance->window) {
        instance->window->close();
        instance->window->deleteLater();
    }

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
    if (!instance || !instance->screen || !instance->window
        || !instance->returnShield || !instance->motion)
        return;

    const bool fullscreen =
        m_compositorBridge->monitorHasFullscreenWindow(instance->screen->name());

    if (instance->fullscreenStateInitialized
        && instance->fullscreenSuppressed == fullscreen)
        return;

    instance->fullscreenStateInitialized = true;
    instance->fullscreenSuppressed = fullscreen;

    if (fullscreen) {
        instance->returnShield->hide();
        instance->motion->snapToCenter();
        instance->window->hide();
        return;
    }

    if (!instance->window->isVisible())
        instance->window->show();

    updateReturnShield(instance);
}

void ShellWindowManager::updateAllFullscreenStates()
{
    for (Instance *instance : m_instances)
        updateFullscreenState(instance);
}
