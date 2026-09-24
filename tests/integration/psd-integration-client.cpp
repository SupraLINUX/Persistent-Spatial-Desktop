#include <QApplication>
#include <QColor>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QPaintEvent>
#include <QPainter>
#include <QPoint>
#include <QTimer>
#include <QWidget>

namespace {

class SolidWindow final : public QWidget
{
public:
    explicit SolidWindow(
        const QColor &color,
        QWidget *parent = nullptr,
        Qt::WindowFlags flags = Qt::WindowFlags{})
        : QWidget(parent, flags)
        , m_color(color)
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
    const QCommandLineOption popupOption(
        QStringLiteral("popup"),
        QStringLiteral("Create a deterministic transient Qt popup for compositor probes."));
    const QCommandLineOption popupColorOption(
        QStringLiteral("popup-color"),
        QStringLiteral("Solid popup color used by render probes."),
        QStringLiteral("color"),
        QStringLiteral("#16f27a"));
    const QCommandLineOption subsurfaceOption(
        QStringLiteral("subsurface"),
        QStringLiteral("Create a deterministic native child surface for compositor probes."));
    const QCommandLineOption subsurfaceColorOption(
        QStringLiteral("subsurface-color"),
        QStringLiteral("Solid native child-surface color used by render probes."),
        QStringLiteral("color"),
        QStringLiteral("#16f27a"));

    parser.addOption(titleOption);
    parser.addOption(colorOption);
    parser.addOption(fullscreenOption);
    parser.addOption(popupOption);
    parser.addOption(popupColorOption);
    parser.addOption(subsurfaceOption);
    parser.addOption(subsurfaceColorOption);
    parser.process(app);

    const QColor color(parser.value(colorOption));
    if (!color.isValid()) {
        qCritical("Invalid --color value");
        return EXIT_FAILURE;
    }

    const QColor popupColor(parser.value(popupColorOption));
    if (parser.isSet(popupOption) && !popupColor.isValid()) {
        qCritical("Invalid --popup-color value");
        return EXIT_FAILURE;
    }

    const QColor subsurfaceColor(parser.value(subsurfaceColorOption));
    if (parser.isSet(subsurfaceOption) && !subsurfaceColor.isValid()) {
        qCritical("Invalid --subsurface-color value");
        return EXIT_FAILURE;
    }

    SolidWindow window(color);
    window.setWindowTitle(parser.value(titleOption));
    window.resize(640, 480);

    if (parser.isSet(fullscreenOption))
        window.showFullScreen();
    else
        window.show();

    if (parser.isSet(popupOption)) {
        auto *popup = new SolidWindow(
            popupColor,
            &window,
            Qt::Popup | Qt::FramelessWindowHint);
        popup->resize(220, 140);

        // The probe first lets Hyprland settle the parent into deterministic
        // floating geometry. Creating the transient afterwards also makes the
        // Wayland protocol trace unambiguous: this surface is an xdg_popup,
        // not a second toplevel window.
        QTimer::singleShot(1200, popup, [popup, &window] {
            popup->move(window.mapToGlobal(QPoint(96, 96)));
            popup->show();
            popup->raise();
        });
    }

    if (parser.isSet(subsurfaceOption)) {
        auto *subsurface = new SolidWindow(
            subsurfaceColor,
            &window,
            Qt::SubWindow | Qt::FramelessWindowHint);
        subsurface->setAttribute(Qt::WA_NativeWindow);
        subsurface->resize(220, 140);
        subsurface->move(96, 96);

        // Forcing a native child window on Qt Wayland gives the probe an
        // independent wl_surface parented through wl_subcompositor. Delay its
        // creation until the toplevel has settled to deterministic geometry.
        QTimer::singleShot(1200, subsurface, [subsurface] {
            subsurface->show();
            subsurface->raise();
        });
    }

    return app.exec();
}
