#include "shell/ShellWindowManager.h"

#include "compositor/HyprlandIpcBridge.h"
#include "core/DesignTokens.h"
#include "core/SpatialLayout.h"
#include "core/SpatialMotionController.h"
#include "core/SpatialState.h"

#include <LayerShellQt/window.h>

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickWindow>
#include <QScreen>
#include <QUrl>

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

    instance->context = new QQmlContext(m_engine->rootContext(), this);
    instance->context->setContextProperty(QStringLiteral("SpatialState"), instance->state);
    instance->context->setContextProperty(QStringLiteral("SpatialLayout"), instance->layout);
    instance->context->setContextProperty(QStringLiteral("SpatialMotion"), instance->motion);
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

    m_instances.insert(screen, instance);
    instance->window->show();
}

void ShellWindowManager::destroyForScreen(QScreen *screen)
{
    Instance *instance = m_instances.take(screen);
    if (!instance)
        return;

    if (instance->window) {
        instance->window->close();
        instance->window->deleteLater();
    }

    if (instance->context)
        instance->context->deleteLater();
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
    layerWindow->setAnchors(
        LayerShellQt::Window::AnchorTop
        | LayerShellQt::Window::AnchorBottom
        | LayerShellQt::Window::AnchorLeft
        | LayerShellQt::Window::AnchorRight);
    layerWindow->setExclusiveZone(-1);
    layerWindow->setKeyboardInteractivity(
        LayerShellQt::Window::KeyboardInteractivityOnDemand);
    layerWindow->setActivateOnShow(false);
}
