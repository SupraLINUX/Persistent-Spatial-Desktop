#include "core/DesignTokens.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QStringList>

DesignTokens::DesignTokens(QObject *parent)
    : QObject(parent)
{
    QFile file(QStringLiteral(":/spec/design-tokens.json"));
    if (!file.open(QIODevice::ReadOnly)) {
        m_errorString = QStringLiteral("Unable to open embedded spec/design-tokens.json");
        return;
    }

    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        m_errorString = QStringLiteral("Invalid design token JSON: %1")
                            .arg(parseError.errorString());
        return;
    }

    if (!document.isObject()) {
        m_errorString = QStringLiteral("Design token root must be a JSON object");
        return;
    }

    m_tokens = document.object().toVariantMap();
    m_loaded = true;
}

bool DesignTokens::loaded() const noexcept
{
    return m_loaded;
}

QString DesignTokens::errorString() const
{
    return m_errorString;
}

QVariantMap DesignTokens::tokens() const
{
    return m_tokens;
}

QVariant DesignTokens::value(const QString &path) const
{
    if (path.isEmpty()) {
        return {};
    }

    QVariant current = m_tokens;
    const QStringList parts = path.split(QLatin1Char('.'), Qt::SkipEmptyParts);

    for (const QString &part : parts) {
        if (!current.canConvert<QVariantMap>()) {
            return {};
        }

        const QVariantMap map = current.toMap();
        const auto iterator = map.constFind(part);
        if (iterator == map.constEnd()) {
            return {};
        }

        current = iterator.value();
    }

    return current;
}
