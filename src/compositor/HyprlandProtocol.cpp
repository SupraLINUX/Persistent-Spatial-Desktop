#include "compositor/HyprlandProtocol.h"

#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QVariantMap>

namespace {

QJsonArray parseArray(const QByteArray &json, QString *error)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(json, &parseError);

    if (parseError.error != QJsonParseError::NoError) {
        if (error)
            *error = parseError.errorString();
        return {};
    }

    if (!document.isArray()) {
        if (error)
            *error = QStringLiteral("Expected a JSON array");
        return {};
    }

    if (error)
        error->clear();

    return document.array();
}

QVariantMap workspaceReference(const QJsonObject &object)
{
    QVariantMap workspace;
    workspace.insert(QStringLiteral("id"), object.value(QStringLiteral("id")).toVariant());
    workspace.insert(QStringLiteral("name"), object.value(QStringLiteral("name")).toString());
    return workspace;
}

} // namespace

QPair<QString, QString> HyprlandProtocol::socketPaths(
    const QString &runtimeDirectory,
    const QString &instanceSignature)
{
    if (runtimeDirectory.isEmpty() || instanceSignature.isEmpty())
        return {};

    const QString base = QDir(runtimeDirectory)
                             .filePath(QStringLiteral("hypr/%1").arg(instanceSignature));
    return {
        QDir(base).filePath(QStringLiteral(".socket.sock")),
        QDir(base).filePath(QStringLiteral(".socket2.sock")),
    };
}

HyprlandProtocol::Event HyprlandProtocol::parseEventLine(const QByteArray &line)
{
    const QByteArray trimmed = line.trimmed();
    const qsizetype separator = trimmed.indexOf(">>");
    if (separator <= 0)
        return {};

    Event event;
    event.name = QString::fromUtf8(trimmed.left(separator));
    event.payload = QString::fromUtf8(trimmed.mid(separator + 2));
    event.valid = !event.name.isEmpty();
    return event;
}


HyprlandProtocol::SpatialGestureBegin HyprlandProtocol::parseSpatialGestureBegin(const QString &payload)
{
    const QStringList parts = payload.split(QLatin1Char(','), Qt::KeepEmptyParts);
    if (parts.size() != 2 || parts.at(0).isEmpty())
        return {};

    bool timeOk = false;
    const quint32 timeMs = parts.at(1).toUInt(&timeOk);
    if (!timeOk)
        return {};

    return {parts.at(0), timeMs, true};
}

HyprlandProtocol::SpatialGestureUpdate HyprlandProtocol::parseSpatialGestureUpdate(const QString &payload)
{
    const QStringList parts = payload.split(QLatin1Char(','), Qt::KeepEmptyParts);
    if (parts.size() != 4 || parts.at(0).isEmpty())
        return {};

    bool xOk = false;
    bool yOk = false;
    bool timeOk = false;
    const double deltaX = parts.at(1).toDouble(&xOk);
    const double deltaY = parts.at(2).toDouble(&yOk);
    const quint32 timeMs = parts.at(3).toUInt(&timeOk);
    if (!xOk || !yOk || !timeOk)
        return {};

    return {parts.at(0), deltaX, deltaY, timeMs, true};
}

HyprlandProtocol::SpatialGestureEnd HyprlandProtocol::parseSpatialGestureEnd(const QString &payload)
{
    const QStringList parts = payload.split(QLatin1Char(','), Qt::KeepEmptyParts);
    if (parts.size() != 3 || parts.at(0).isEmpty())
        return {};

    bool cancelledOk = false;
    bool timeOk = false;
    const int cancelledValue = parts.at(1).toInt(&cancelledOk);
    const quint32 timeMs = parts.at(2).toUInt(&timeOk);
    if (!cancelledOk || !timeOk || (cancelledValue != 0 && cancelledValue != 1))
        return {};

    return {parts.at(0), cancelledValue == 1, timeMs, true};
}

QVariantList HyprlandProtocol::parseMonitors(const QByteArray &json, QString *error)
{
    const QJsonArray array = parseArray(json, error);
    QVariantList monitors;
    monitors.reserve(array.size());

    for (const QJsonValue &value : array) {
        if (!value.isObject())
            continue;

        const QJsonObject object = value.toObject();
        QVariantMap monitor;
        monitor.insert(QStringLiteral("id"), object.value(QStringLiteral("id")).toVariant());
        monitor.insert(QStringLiteral("name"), object.value(QStringLiteral("name")).toString());
        monitor.insert(QStringLiteral("description"), object.value(QStringLiteral("description")).toString());
        monitor.insert(QStringLiteral("x"), object.value(QStringLiteral("x")).toInt());
        monitor.insert(QStringLiteral("y"), object.value(QStringLiteral("y")).toInt());
        monitor.insert(QStringLiteral("width"), object.value(QStringLiteral("width")).toInt());
        monitor.insert(QStringLiteral("height"), object.value(QStringLiteral("height")).toInt());
        monitor.insert(QStringLiteral("scale"), object.value(QStringLiteral("scale")).toDouble(1.0));
        monitor.insert(QStringLiteral("focused"), object.value(QStringLiteral("focused")).toBool());
        monitor.insert(QStringLiteral("dpmsStatus"), object.value(QStringLiteral("dpmsStatus")).toBool(true));

        const QJsonObject activeWorkspace = object.value(QStringLiteral("activeWorkspace")).toObject();
        monitor.insert(QStringLiteral("activeWorkspace"), workspaceReference(activeWorkspace));
        monitors.append(monitor);
    }

    return monitors;
}

QVariantList HyprlandProtocol::parseWorkspaces(const QByteArray &json, QString *error)
{
    const QJsonArray array = parseArray(json, error);
    QVariantList workspaces;
    workspaces.reserve(array.size());

    for (const QJsonValue &value : array) {
        if (!value.isObject())
            continue;

        const QJsonObject object = value.toObject();
        QVariantMap workspace;
        workspace.insert(QStringLiteral("id"), object.value(QStringLiteral("id")).toVariant());
        workspace.insert(QStringLiteral("name"), object.value(QStringLiteral("name")).toString());
        workspace.insert(QStringLiteral("monitor"), object.value(QStringLiteral("monitor")).toString());
        workspace.insert(QStringLiteral("monitorId"), object.value(QStringLiteral("monitorID")).toVariant());
        workspace.insert(QStringLiteral("windows"), object.value(QStringLiteral("windows")).toInt());
        workspace.insert(QStringLiteral("hasFullscreen"), object.value(QStringLiteral("hasfullscreen")).toBool());
        workspace.insert(QStringLiteral("lastWindow"), object.value(QStringLiteral("lastwindow")).toString());
        workspace.insert(QStringLiteral("lastWindowTitle"), object.value(QStringLiteral("lastwindowtitle")).toString());
        workspaces.append(workspace);
    }

    return workspaces;
}

QVariantList HyprlandProtocol::parseWindows(const QByteArray &json, QString *error)
{
    const QJsonArray array = parseArray(json, error);
    QVariantList windows;
    windows.reserve(array.size());

    for (const QJsonValue &value : array) {
        if (!value.isObject())
            continue;

        const QJsonObject object = value.toObject();
        QVariantMap window;
        window.insert(QStringLiteral("address"), object.value(QStringLiteral("address")).toString());
        window.insert(QStringLiteral("class"), object.value(QStringLiteral("class")).toString());
        window.insert(QStringLiteral("title"), object.value(QStringLiteral("title")).toString());
        window.insert(QStringLiteral("initialClass"), object.value(QStringLiteral("initialClass")).toString());
        window.insert(QStringLiteral("initialTitle"), object.value(QStringLiteral("initialTitle")).toString());
        window.insert(QStringLiteral("pid"), object.value(QStringLiteral("pid")).toVariant());
        window.insert(QStringLiteral("monitorId"), object.value(QStringLiteral("monitor")).toVariant());
        window.insert(QStringLiteral("workspace"), workspaceReference(object.value(QStringLiteral("workspace")).toObject()));
        window.insert(QStringLiteral("floating"), object.value(QStringLiteral("floating")).toBool());
        window.insert(QStringLiteral("fullscreen"), object.value(QStringLiteral("fullscreen")).toInt());
        window.insert(QStringLiteral("pinned"), object.value(QStringLiteral("pinned")).toBool());
        window.insert(QStringLiteral("xwayland"), object.value(QStringLiteral("xwayland")).toBool());
        window.insert(QStringLiteral("mapped"), object.value(QStringLiteral("mapped")).toBool(true));

        const QJsonArray at = object.value(QStringLiteral("at")).toArray();
        if (at.size() >= 2) {
            window.insert(QStringLiteral("x"), at.at(0).toInt());
            window.insert(QStringLiteral("y"), at.at(1).toInt());
        }

        const QJsonArray size = object.value(QStringLiteral("size")).toArray();
        if (size.size() >= 2) {
            window.insert(QStringLiteral("width"), size.at(0).toInt());
            window.insert(QStringLiteral("height"), size.at(1).toInt());
        }

        windows.append(window);
    }

    return windows;
}
