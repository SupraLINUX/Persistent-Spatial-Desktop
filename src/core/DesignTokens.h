#pragma once

#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantMap>

class DesignTokens final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool loaded READ loaded CONSTANT)
    Q_PROPERTY(QString errorString READ errorString CONSTANT)
    Q_PROPERTY(QVariantMap tokens READ tokens CONSTANT)

public:
    explicit DesignTokens(QObject *parent = nullptr);

    [[nodiscard]] bool loaded() const noexcept;
    [[nodiscard]] QString errorString() const;
    [[nodiscard]] QVariantMap tokens() const;

    Q_INVOKABLE QVariant value(const QString &path) const;

private:
    bool m_loaded = false;
    QString m_errorString;
    QVariantMap m_tokens;
};
