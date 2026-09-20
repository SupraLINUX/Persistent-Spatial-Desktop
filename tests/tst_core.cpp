#include "compositor/CompositorBridge.h"
#include "compositor/HyprlandProtocol.h"
#include "compositor/SpatialCompositorSync.h"
#include "core/DesignTokens.h"
#include "core/SpatialLayout.h"
#include "core/SpatialMotionController.h"
#include "core/SpatialState.h"

#include <QSignalSpy>
#include <QVariantMap>
#include <QtTest>

#include <algorithm>

class TestCompositorBridge final : public CompositorBridge
{
public:
    struct TransformCommand {
        quint64 id = 0;
        QString monitorName;
        QPointF offset;
        bool reset = false;
    };

    using CompositorBridge::CompositorBridge;

    QString backendName() const override
    {
        return QStringLiteral("test");
    }

    bool spatialTransformAvailable() const override
    {
        return m_spatialTransformAvailable;
    }

    quint64 setSpatialTransformOffset(
        const QString &monitorName, double x, double y) override
    {
        const quint64 commandId = allocateSpatialTransformCommandId();
        m_transformCommands.push_back(
            TransformCommand{commandId, monitorName, QPointF{x, y}, false});
        return commandId;
    }

    quint64 resetSpatialTransformOffset(const QString &monitorName) override
    {
        const quint64 commandId = allocateSpatialTransformCommandId();
        m_transformCommands.push_back(
            TransformCommand{commandId, monitorName, QPointF{}, true});
        return commandId;
    }

    void start() override {}
    void refreshAll() override {}

    void inject(const QVariantList &monitors, const QVariantList &windows)
    {
        setMonitors(monitors);
        setWindows(windows);
    }

    void notifyMonitorsChanged()
    {
        emit monitorsChanged();
    }

    void setSpatialTransformAvailable(bool available)
    {
        if (m_spatialTransformAvailable == available)
            return;

        m_spatialTransformAvailable = available;
        emit capabilitiesChanged();
    }

    const QVector<TransformCommand> &transformCommands() const
    {
        return m_transformCommands;
    }

    void finishTransformCommand(
        quint64 commandId,
        bool success = true,
        const QString &message = QStringLiteral("ok"))
    {
        const auto it = std::find_if(
            m_transformCommands.cbegin(),
            m_transformCommands.cend(),
            [commandId](const TransformCommand &command) {
                return command.id == commandId;
            });

        const QString monitorName =
            it == m_transformCommands.cend()
                ? QStringLiteral("DP-1")
                : it->monitorName;

        emit spatialTransformCommandFinished(
            commandId, monitorName, success, message);
    }

private:
    bool m_spatialTransformAvailable = false;
    QVector<TransformCommand> m_transformCommands;
};

class CoreTest final : public QObject
{
    Q_OBJECT

private slots:
    void designTokensLoad();
    void spatialStateStartsCentered();
    void spatialStateNavigates();
    void spatialStateRejectsUnknownDestination();
    void spatialLayoutComputesResponsiveGeometry();
    void spatialLayoutComputesReturnShieldMargins();
    void spatialMotionUsesSingleAuthoritativeOffset();
    void spatialMotionSnapToCenterIsImmediate();
    void spatialGestureTracksOneToOneProgress();
    void spatialGestureCommitsByDistance();
    void spatialGestureCommitsByVelocity();
    void spatialGestureCancelsExplicitly();
    void spatialCompositorSyncSerializesFinalReset();
    void spatialCompositorSyncRetargetsCurrentOffset();
    void spatialCompositorSyncCentersOnCapabilityLoss();
    void spatialCompositorSyncShutdownDrainsFinalReset();
    void hyprlandSocketPaths();
    void hyprlandEventParsing();
    void hyprlandSpatialGestureParsing();
    void hyprlandMonitorParsing();
    void hyprlandWorkspaceParsing();
    void hyprlandWindowParsing();
    void compositorFullscreenDetectionUsesActiveWorkspace();
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

void CoreTest::spatialLayoutComputesReturnShieldMargins()
{
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1920, 1080));

    const int gutter = qRound(layout.gutter());
    QCOMPARE(layout.returnShieldMargins(QStringLiteral("left")),
             QMargins(qRound(layout.leftWidth()), gutter, 0, gutter));
    QCOMPARE(layout.returnShieldMargins(QStringLiteral("right")),
             QMargins(0, gutter, qRound(layout.rightWidth()), gutter));
    QCOMPARE(layout.returnShieldMargins(QStringLiteral("top")),
             QMargins(gutter, qRound(layout.topHeight()), gutter, 0));
    QCOMPARE(layout.returnShieldMargins(QStringLiteral("dash")),
             QMargins(gutter, 0, gutter, 1080 - (gutter * 2)));
    QCOMPARE(layout.returnShieldMargins(QStringLiteral("center")), QMargins());
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



void CoreTest::spatialMotionSnapToCenterIsImmediate()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    motion.setDurationMs(1000);

    QVERIFY(motion.navigate(QStringLiteral("left")));
    QVERIFY(motion.running());

    motion.snapToCenter();

    QVERIFY(!motion.running());
    QVERIFY(!motion.gestureActive());
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(motion.targetSurface(), QStringLiteral("center"));
    QCOMPARE(motion.offset(), QPointF());
}

void CoreTest::spatialGestureTracksOneToOneProgress()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    const QPointF destination = layout.offsetForSurface(QStringLiteral("left"));

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.gestureActive());
    QVERIFY(motion.updateGesture(destination.x() * 0.5, 1.0));

    QCOMPARE(motion.targetSurface(), QStringLiteral("left"));
    QVERIFY(qAbs(motion.gestureProgress() - 0.5) < 0.0001);
    QVERIFY(qAbs(motion.offsetX() - (destination.x() * 0.5)) < 0.0001);
    QCOMPARE(motion.offsetY(), 0.0);
}

void CoreTest::spatialGestureCommitsByDistance()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    motion.setDurationMs(1);
    const QPointF destination = layout.offsetForSurface(QStringLiteral("top"));

    QSignalSpy finishedSpy(&motion, &SpatialMotionController::transitionFinished);

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(0.0, destination.y() * 0.6));
    QVERIFY(motion.endGesture(0.0, 0.0));

    QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.count(), 1, 100);
    QCOMPARE(state.currentSurface(), QStringLiteral("top"));
    QCOMPARE(motion.offset(), destination);
}

void CoreTest::spatialGestureCommitsByVelocity()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    motion.setDurationMs(1);
    const QPointF destination = layout.offsetForSurface(QStringLiteral("right"));

    QSignalSpy finishedSpy(&motion, &SpatialMotionController::transitionFinished);

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(destination.x() * 0.1, 0.0));
    QVERIFY(motion.gestureProgress() < 0.45);
    QVERIFY(motion.endGesture(destination.x() * 1.2, 0.0));

    QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.count(), 1, 100);
    QCOMPARE(state.currentSurface(), QStringLiteral("right"));
    QCOMPARE(motion.offset(), destination);
}

void CoreTest::spatialGestureCancelsExplicitly()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    motion.setDurationMs(1);
    const QPointF destination = layout.offsetForSurface(QStringLiteral("dash"));

    QSignalSpy finishedSpy(&motion, &SpatialMotionController::transitionFinished);

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(0.0, destination.y() * 0.8));
    QVERIFY(motion.endGesture(0.0, destination.y() * 2.0, true));

    QTRY_COMPARE_WITH_TIMEOUT(finishedSpy.count(), 1, 100);
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(motion.offset(), QPointF());
}

void CoreTest::spatialCompositorSyncSerializesFinalReset()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    TestCompositorBridge bridge;
    bridge.setSpatialTransformAvailable(true);

    SpatialCompositorSync sync(
        &motion, &bridge, QStringLiteral("DP-1"));

    sync.setEnabled(true);
    QCOMPARE(bridge.transformCommands().size(), 1);
    QVERIFY(bridge.transformCommands().at(0).reset);

    bridge.finishTransformCommand(bridge.transformCommands().at(0).id);
    QVERIFY(sync.idle());

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(120.0, 0.0));

    QCOMPARE(bridge.transformCommands().size(), 2);
    const auto inFlight = bridge.transformCommands().at(1);
    QVERIFY(!inFlight.reset);
    QVERIFY(inFlight.offset.x() > 0.0);

    QVERIFY(motion.updateGesture(80.0, 0.0));
    QCOMPARE(bridge.transformCommands().size(), 2);

    sync.setEnabled(false);
    QCOMPARE(bridge.transformCommands().size(), 2);
    QVERIFY(!sync.idle());

    bridge.finishTransformCommand(inFlight.id + 1000);
    QCOMPARE(bridge.transformCommands().size(), 2);
    QVERIFY(!sync.idle());

    bridge.finishTransformCommand(inFlight.id);

    QCOMPARE(bridge.transformCommands().size(), 3);
    const auto finalReset = bridge.transformCommands().at(2);
    QVERIFY(finalReset.reset);
    QCOMPARE(finalReset.monitorName, QStringLiteral("DP-1"));
    QVERIFY(!sync.idle());

    bridge.finishTransformCommand(finalReset.id);
    QVERIFY(sync.idle());
    QVERIFY(sync.lastError().isEmpty());
}

void CoreTest::spatialCompositorSyncRetargetsCurrentOffset()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    TestCompositorBridge bridge;
    bridge.setSpatialTransformAvailable(true);

    SpatialCompositorSync sync(
        &motion, &bridge, QStringLiteral("DP-1"));

    sync.setEnabled(true);
    bridge.finishTransformCommand(bridge.transformCommands().at(0).id);

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(120.0, 0.0));

    const quint64 firstOffsetId = bridge.transformCommands().last().id;
    bridge.finishTransformCommand(firstOffsetId);
    QVERIFY(sync.idle());

    const int commandCountBeforeRetarget = bridge.transformCommands().size();
    bridge.notifyMonitorsChanged();

    QCOMPARE(bridge.transformCommands().size(), commandCountBeforeRetarget + 1);
    const auto retarget = bridge.transformCommands().last();
    QVERIFY(!retarget.reset);
    QCOMPARE(retarget.offset, motion.offset());

    bridge.finishTransformCommand(retarget.id);
    QVERIFY(sync.idle());
}

void CoreTest::spatialCompositorSyncCentersOnCapabilityLoss()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    TestCompositorBridge bridge;
    bridge.setSpatialTransformAvailable(true);

    SpatialCompositorSync sync(
        &motion, &bridge, QStringLiteral("DP-1"));

    sync.setEnabled(true);
    bridge.finishTransformCommand(bridge.transformCommands().at(0).id);
    QVERIFY(sync.idle());

    QVERIFY(state.navigate(QStringLiteral("left")));
    QCOMPARE(state.currentSurface(), QStringLiteral("left"));
    QVERIFY(!motion.offset().isNull());

    const auto offsetCommand = bridge.transformCommands().last();
    QVERIFY(!offsetCommand.reset);
    bridge.finishTransformCommand(offsetCommand.id);
    QVERIFY(sync.idle());

    const int commandCountBeforeLoss = bridge.transformCommands().size();
    bridge.setSpatialTransformAvailable(false);

    QVERIFY(!sync.active());
    QCOMPARE(state.currentSurface(), QStringLiteral("center"));
    QCOMPARE(motion.offset(), QPointF());
    QVERIFY(!motion.running());
    QCOMPARE(bridge.transformCommands().size(), commandCountBeforeLoss);

    bridge.setSpatialTransformAvailable(true);
    QVERIFY(sync.active());
    QCOMPARE(bridge.transformCommands().size(), commandCountBeforeLoss + 1);

    const auto recoveryReset = bridge.transformCommands().last();
    QVERIFY(recoveryReset.reset);
    QCOMPARE(recoveryReset.monitorName, QStringLiteral("DP-1"));

    bridge.finishTransformCommand(recoveryReset.id);
    QVERIFY(sync.idle());
    QVERIFY(sync.lastError().isEmpty());
}

void CoreTest::spatialCompositorSyncShutdownDrainsFinalReset()
{
    SpatialState state;
    SpatialLayout layout;
    layout.setViewportSize(QSizeF(1280, 800));

    SpatialMotionController motion(&state, &layout);
    TestCompositorBridge bridge;
    bridge.setSpatialTransformAvailable(true);

    SpatialCompositorSync sync(
        &motion, &bridge, QStringLiteral("DP-1"));

    sync.setEnabled(true);
    bridge.finishTransformCommand(bridge.transformCommands().at(0).id);

    QVERIFY(motion.beginGesture());
    QVERIFY(motion.updateGesture(120.0, 0.0));

    const quint64 offsetCommandId = bridge.transformCommands().last().id;

    QTimer::singleShot(0, &sync, [&bridge, &sync, offsetCommandId] {
        bridge.finishTransformCommand(offsetCommandId);

        QTimer::singleShot(0, &sync, [&bridge] {
            const auto &commands = bridge.transformCommands();
            QVERIFY(commands.last().reset);
            bridge.finishTransformCommand(commands.last().id);
        });
    });

    QVERIFY(sync.shutdownAndReset(200));
    QVERIFY(sync.idle());
    QVERIFY(sync.lastError().isEmpty());
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


void CoreTest::hyprlandSpatialGestureParsing()
{
    const auto begin = HyprlandProtocol::parseSpatialGestureBegin(
        QStringLiteral("DP-1,1200"));
    QVERIFY(begin.valid);
    QCOMPARE(begin.monitorName, QStringLiteral("DP-1"));
    QCOMPARE(begin.timeMs, quint32(1200));

    const auto update = HyprlandProtocol::parseSpatialGestureUpdate(
        QStringLiteral("DP-1,12.5,-7.25,1216"));
    QVERIFY(update.valid);
    QCOMPARE(update.monitorName, QStringLiteral("DP-1"));
    QCOMPARE(update.deltaX, 12.5);
    QCOMPARE(update.deltaY, -7.25);
    QCOMPARE(update.timeMs, quint32(1216));

    const auto end = HyprlandProtocol::parseSpatialGestureEnd(
        QStringLiteral("DP-1,1,1232"));
    QVERIFY(end.valid);
    QCOMPARE(end.monitorName, QStringLiteral("DP-1"));
    QVERIFY(end.cancelled);
    QCOMPARE(end.timeMs, quint32(1232));

    QVERIFY(!HyprlandProtocol::parseSpatialGestureBegin(QStringLiteral("broken")).valid);
    QVERIFY(!HyprlandProtocol::parseSpatialGestureUpdate(QStringLiteral("DP-1,x,1,2")).valid);
    QVERIFY(!HyprlandProtocol::parseSpatialGestureEnd(QStringLiteral("DP-1,2,3")).valid);
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


void CoreTest::compositorFullscreenDetectionUsesActiveWorkspace()
{
    TestCompositorBridge bridge;

    const QVariantMap monitor{
        {QStringLiteral("id"), 0},
        {QStringLiteral("name"), QStringLiteral("DP-1")},
        {QStringLiteral("activeWorkspace"), QVariantMap{
            {QStringLiteral("id"), 3},
            {QStringLiteral("name"), QStringLiteral("3")},
        }},
    };

    QVariantMap window{
        {QStringLiteral("mapped"), true},
        {QStringLiteral("fullscreen"), 1},
        {QStringLiteral("monitorId"), 0},
        {QStringLiteral("workspace"), QVariantMap{
            {QStringLiteral("id"), 3},
            {QStringLiteral("name"), QStringLiteral("3")},
        }},
    };

    bridge.inject(QVariantList{monitor}, QVariantList{window});
    QVERIFY(bridge.monitorHasFullscreenWindow(QStringLiteral("DP-1")));

    window.insert(
        QStringLiteral("workspace"),
        QVariantMap{{QStringLiteral("id"), 4}, {QStringLiteral("name"), QStringLiteral("4")}});
    bridge.inject(QVariantList{monitor}, QVariantList{window});
    QVERIFY(!bridge.monitorHasFullscreenWindow(QStringLiteral("DP-1")));

    window.insert(
        QStringLiteral("workspace"),
        QVariantMap{{QStringLiteral("id"), 3}, {QStringLiteral("name"), QStringLiteral("3")}});
    window.insert(QStringLiteral("mapped"), false);
    bridge.inject(QVariantList{monitor}, QVariantList{window});
    QVERIFY(!bridge.monitorHasFullscreenWindow(QStringLiteral("DP-1")));

    window.insert(QStringLiteral("mapped"), true);
    window.insert(QStringLiteral("fullscreen"), 0);
    bridge.inject(QVariantList{monitor}, QVariantList{window});
    QVERIFY(!bridge.monitorHasFullscreenWindow(QStringLiteral("DP-1")));

    QVERIFY(!bridge.monitorHasFullscreenWindow(QStringLiteral("HDMI-A-1")));
}

QTEST_GUILESS_MAIN(CoreTest)

#include "tst_core.moc"
