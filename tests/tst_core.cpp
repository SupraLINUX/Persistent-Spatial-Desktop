#include "compositor/HyprlandProtocol.h"
#include "core/DesignTokens.h"
#include "core/SpatialLayout.h"
#include "core/SpatialMotionController.h"
#include "core/SpatialState.h"

#include <QSignalSpy>
#include <QVariantMap>
#include <QtTest>

class CoreTest final : public QObject
{
    Q_OBJECT

private slots:
    void designTokensLoad();
    void spatialStateStartsCentered();
    void spatialStateNavigates();
    void spatialStateRejectsUnknownDestination();
    void spatialLayoutComputesResponsiveGeometry();
    void spatialMotionUsesSingleAuthoritativeOffset();
    void hyprlandSocketPaths();
    void hyprlandEventParsing();
    void hyprlandMonitorParsing();
    void hyprlandWorkspaceParsing();
    void hyprlandWindowParsing();
};

void CoreTest::designTokensLoad()
{
    DesignTokens tokens;
    QVERIFY2(tokens.loaded(), qPrintable(tokens.errorString()));
    QCOMPARE(tokens.value(QStringLiteral("designSystem")).toString(),
             QStringLiteral("Spatial Glass"));
    QCOMPARE(tokens.value(QStringLiteral("colors.accent.primary")).toString(),
             QStringLiteral("#A9B7FF"));
}

void CoreTest::spatialStateStartsCentered()
{
    SpatialState state;
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
}

void CoreTest::spatialStateNavigates()
{
    SpatialState state;
    QSignalSpy spy(&state, &SpatialState::currentSurfaceChanged);

    QVERIFY(state.navigate(QStringLiteral("left")));
    QCOMPARE(state.currentSurface(), QStringLiteral("left"));
    QCOMPARE(spy.count(), 1);

    state.center();
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(spy.count(), 2);
}

void CoreTest::spatialStateRejectsUnknownDestination()
{
    SpatialState state;
    QSignalSpy spy(&state, &SpatialState::currentSurfaceChanged);

    QVERIFY(!state.navigate(QStringLiteral("bottom")));
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(spy.count(), 0);
}


void CoreTest::spatialLayoutComputesResponsiveGeometry()
{
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1920, 1080));

    QCOMPARE(layout.gutter(), 12.96);
    QCOMPARE(layout.leftWidth(), 460.0);
    QCOMPARE(layout.rightWidth(), 499.2);
    QCOMPARE(layout.topHeight(), 270.0);

    const QPointF left = layout.offsetForSurface(QStringLiteral("left"));
    QCOMPARE(left.x(), layout.leftWidth() - layout.gutter());
    QCOMPARE(left.y(), 0.0);

    const QPointF dash = layout.offsetForSurface(QStringLiteral("dash"));
    QCOMPARE(dash.x(), 0.0);
    QCOMPARE(dash.y(), -(1080.0 - (layout.gutter() * 3.0)));
}

void CoreTest::spatialMotionUsesSingleAuthoritativeOffset()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    motion.setDurationMs(1);

    QSignalSpy offsetSpy(&motion, &SpatialMotionController::offsetChanged);
    QSignalSpy finishedSpy(&motion, &SpatialMotionController::transitionFinished);

    QVERIFY(motion.navigate(QStringLiteral("left")));
    QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.count(), 1, 100);
    QCOMPARE(state.currentSurface(), QStringLiteral("left"));
    QCOMPARE(motion.offset(), layout.offsetForSurface(QStringLiteral("left")));
    QVERIFY(offsetSpy.count() > 0);

    motion.center();
    QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.count(), 2, 100);
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(motion.offset(), QPointF());
}

void CoreTest::hyprlandSocketPaths()
{
    const auto paths = HyprlandProtocol::socketPaths(
        QStringLiteral("/run/user/1000"),
        QStringLiteral("instance-123"));

    QCOMPARE(paths.first, QStringLiteral("/run/user/1000/hypr/instance-123/.socket.sock"));
    QCOMPARE(paths.second, QStringLiteral("/run/user/1000/hypr/instance-123/.socket2.sock"));
}

void CoreTest::hyprlandEventParsing()
{
    const auto event = HyprlandProtocol::parseEventLine(
        QByteArrayLiteral("openwindow>>0xabc,1,org.example.App,Example\n"));

    QVERIFY(event.valid);
    QCOMPARE(event.name, QStringLiteral("openwindow"));
    QCOMPARE(event.payload, QStringLiteral("0xabc,1,org.example.App,Example"));

    QVERIFY(!HyprlandProtocol::parseEventLine(QByteArrayLiteral("invalid")).valid);
}

void CoreTest::hyprlandMonitorParsing()
{
    const QByteArray json = R"json([
      {
        "id": 0,
        "name": "DP-1",
        "description": "Example Display",
        "x": 0,
        "y": 0,
        "width": 2560,
        "height": 1440,
        "scale": 1.0,
        "focused": true,
        "dpmsStatus": true,
        "activeWorkspace": {"id": 3, "name": "3"}
      }
    ])json";

    QString error;
    const QVariantList monitors = HyprlandProtocol::parseMonitors(json, &error);
    QVERIFY2(error.isEmpty(), qPrintable(error));
    QCOMPARE(monitors.size(), 1);

    const QVariantMap monitor = monitors.first().toMap();
    QCOMPARE(monitor.value(QStringLiteral("name")).toString(), QStringLiteral("DP-1"));
    QCOMPARE(monitor.value(QStringLiteral("width")).toInt(), 2560);
    QCOMPARE(monitor.value(QStringLiteral("activeWorkspace")).toMap().value(QStringLiteral("id")).toInt(), 3);
}

void CoreTest::hyprlandWorkspaceParsing()
{
    const QByteArray json = R"json([
      {
        "id": 3,
        "name": "3",
        "monitor": "DP-1",
        "monitorID": 0,
        "windows": 2,
        "hasfullscreen": false,
        "lastwindow": "0xabc",
        "lastwindowtitle": "Example"
      }
    ])json";

    QString error;
    const QVariantList workspaces = HyprlandProtocol::parseWorkspaces(json, &error);
    QVERIFY2(error.isEmpty(), qPrintable(error));
    QCOMPARE(workspaces.size(), 1);

    const QVariantMap workspace = workspaces.first().toMap();
    QCOMPARE(workspace.value(QStringLiteral("monitor")).toString(), QStringLiteral("DP-1"));
    QCOMPARE(workspace.value(QStringLiteral("windows")).toInt(), 2);
}

void CoreTest::hyprlandWindowParsing()
{
    const QByteArray json = R"json([
      {
        "address": "0xabc",
        "mapped": true,
        "at": [100, 200],
        "size": [1200, 800],
        "workspace": {"id": 3, "name": "3"},
        "floating": true,
        "monitor": 0,
        "class": "org.example.App",
        "title": "Example",
        "initialClass": "org.example.App",
        "initialTitle": "Example",
        "pid": 4242,
        "xwayland": false,
        "pinned": false,
        "fullscreen": 0
      }
    ])json";

    QString error;
    const QVariantList windows = HyprlandProtocol::parseWindows(json, &error);
    QVERIFY2(error.isEmpty(), qPrintable(error));
    QCOMPARE(windows.size(), 1);

    const QVariantMap window = windows.first().toMap();
    QCOMPARE(window.value(QStringLiteral("address")).toString(), QStringLiteral("0xabc"));
    QCOMPARE(window.value(QStringLiteral("class")).toString(), QStringLiteral("org.example.App"));
    QCOMPARE(window.value(QStringLiteral("x")).toInt(), 100);
    QCOMPARE(window.value(QStringLiteral("height")).toInt(), 800);
    QVERIFY(window.value(QStringLiteral("floating")).toBool());
}

QTEST_GUILESS_MAIN(CoreTest)

#include "tst_core.moc"
