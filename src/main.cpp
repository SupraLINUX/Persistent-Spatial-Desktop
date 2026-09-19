#include "compositor/HyprlandIpcBridge.h"
#include "core/DesignTokens.h"
#include "shell/ShellWindowManager.h"

#include <LayerShellQt/shell.h>

#include <QCoreApplication>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>

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

    HyprlandIpcBridge compositorBridge;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("DesignTokens"), &designTokens);
    engine.rootContext()->setContextProperty(QStringLiteral("CompositorBridge"), &compositorBridge);

    ShellWindowManager shellWindows(&engine, &designTokens, &compositorBridge);

    compositorBridge.start();
    shellWindows.start();

    if (shellWindows.windowCount() == 0) {
        qCritical() << "PSD could not create a shell surface for any screen";
        return EXIT_FAILURE;
    }

    return application.exec();
}
