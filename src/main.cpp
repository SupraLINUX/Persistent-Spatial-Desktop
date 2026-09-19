#include "core/DesignTokens.h"
#include "core/SpatialState.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QUrl>

int main(int argc, char *argv[])
{
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

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("DesignTokens"), &designTokens);
    engine.rootContext()->setContextProperty(QStringLiteral("SpatialState"), &spatialState);

    engine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (engine.rootObjects().isEmpty()) {
        qCritical() << "PSD failed to create the QML root object";
        return EXIT_FAILURE;
    }

    return application.exec();
}
