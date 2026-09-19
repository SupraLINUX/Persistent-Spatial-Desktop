#include "compositor/HyprlandIpcBridge.h"
#include "core/DesignTokens.h"
#include "core/SpatialLayout.h"
#include "core/SpatialMotionController.h"
#include "core/SpatialState.h"

#include <LayerShellQt/shell.h>
#include <LayerShellQt/window.h>

#include <QCoreApplication>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QUrl>

int main(int argc, char *argv[])
{
    LayerShellQt::Shell::useLayerShell();

    QGuiApplication application(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("psd-shell"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QCoreApplication::setOrganizationName(QStringLiteral("SupraLINUX"));

    DesignTokens designTokens;
    if (!designTokens.loaded()) {
        qCritical().noquote() << "PSD failed to load design tokens:"
                              << designTokens.errorString();
        return EXIT_FAILURE;
    }

    SpatialState spatialState;
    SpatialLayout spatialLayout;
    SpatialMotionController spatialMotion(&spatialState, &spatialLayout);
    spatialMotion.setDurationMs(
        designTokens.value(QStringLiteral("motion.durationMs.spatial")).toInt());

    HyprlandIpcBridge compositorBridge;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("DesignTokens"), &designTokens);
    engine.rootContext()->setContextProperty(QStringLiteral("SpatialState"), &spatialState);
    engine.rootContext()->setContextProperty(QStringLiteral("SpatialLayout"), &spatialLayout);
    engine.rootContext()->setContextProperty(QStringLiteral("SpatialMotion"), &spatialMotion);
    engine.rootContext()->setContextProperty(QStringLiteral("CompositorBridge"), &compositorBridge);

    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "PSD failed to create the QML root object";
        return EXIT_FAILURE;
    }

    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!window) {
        qCritical() << "PSD QML root is not a QQuickWindow";
        return EXIT_FAILURE;
    }

    auto *layerWindow = LayerShellQt::Window::get(window);
    if (!layerWindow) {
        qCritical() << "PSD failed to create its layer-shell surface";
        return EXIT_FAILURE;
    }

    layerWindow->setScope(QStringLiteral("psd-shell"));
    layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
    layerWindow->setAnchors(
        LayerShellQt::Window::AnchorTop
        | LayerShellQt::Window::AnchorBottom
        | LayerShellQt::Window::AnchorLeft
        | LayerShellQt::Window::AnchorRight);
    layerWindow->setExclusiveZone(-1);
    layerWindow->setKeyboardInteractivity(
        LayerShellQt::Window::KeyboardInteractivityOnDemand);

    compositorBridge.start();
    window->show();

    return application.exec();
}
