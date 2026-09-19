#include "core/DesignTokens.h"
#include "core/SpatialState.h"

#include <QSignalSpy>
#include <QtTest>

class CoreTest final : public QObject
{
    Q_OBJECT

private slots:
    void designTokensLoad();
    void spatialStateStartsCentered();
    void spatialStateNavigates();
    void spatialStateRejectsUnknownDestination();
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

QTEST_APPLESS_MAIN(CoreTest)

#include "tst_core.moc"
