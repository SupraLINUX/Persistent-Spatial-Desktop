#include <QApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QWidget>

int main(int argc, char *argv[])
{
    QCoreApplication::setApplicationName(QStringLiteral("psd-integration-client"));

    QApplication app(argc, argv);

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Deterministic PSD Wayland integration-test client"));
    parser.addHelpOption();

    QCommandLineOption titleOption(
        QStringList{QStringLiteral("t"), QStringLiteral("title")},
        QStringLiteral("Top-level window title."),
        QStringLiteral("title"),
        QStringLiteral("PSD Integration Client"));
    const QCommandLineOption fullscreenOption(
        QStringLiteral("fullscreen"),
        QStringLiteral("Request compositor fullscreen immediately."));

    parser.addOption(titleOption);
    parser.addOption(fullscreenOption);
    parser.process(app);

    QWidget window;
    window.setWindowTitle(parser.value(titleOption));
    window.resize(640, 480);

    if (parser.isSet(fullscreenOption))
        window.showFullScreen();
    else
        window.show();

    return app.exec();
}
