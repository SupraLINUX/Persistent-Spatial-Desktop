#include <QApplication>
#include <QColor>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QPaintEvent>
#include <QPainter>
#include <QWidget>

namespace {

class SolidWindow final : public QWidget
{
public:
    explicit SolidWindow(const QColor &color)
        : m_color(color)
    {
        setAttribute(Qt::WA_OpaquePaintEvent);
    }

protected:
    void paintEvent(QPaintEvent *event) override
    {
        Q_UNUSED(event);
        QPainter painter(this);
        painter.fillRect(rect(), m_color);
    }

private:
    QColor m_color;
};

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication::setApplicationName(QStringLiteral("psd-integration-client"));

    QApplication app(argc, argv);

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("Deterministic PSD Wayland integration-test client"));
    parser.addHelpOption();

    const QCommandLineOption titleOption(
        QStringList{QStringLiteral("t"), QStringLiteral("title")},
        QStringLiteral("Top-level window title."),
        QStringLiteral("title"),
        QStringLiteral("PSD Integration Client"));
    const QCommandLineOption colorOption(
        QStringLiteral("color"),
        QStringLiteral("Solid client-area color used by render probes."),
        QStringLiteral("color"),
        QStringLiteral("#202838"));
    const QCommandLineOption fullscreenOption(
        QStringLiteral("fullscreen"),
        QStringLiteral("Request compositor fullscreen immediately."));

    parser.addOption(titleOption);
    parser.addOption(colorOption);
    parser.addOption(fullscreenOption);
    parser.process(app);

    const QColor color(parser.value(colorOption));
    if (!color.isValid()) {
        qCritical("Invalid --color value");
        return EXIT_FAILURE;
    }

    SolidWindow window(color);
    window.setWindowTitle(parser.value(titleOption));
    window.resize(640, 480);

    if (parser.isSet(fullscreenOption))
        window.showFullScreen();
    else
        window.show();

    return app.exec();
}
