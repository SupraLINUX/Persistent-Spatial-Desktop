#include "compositor/HyprlandIpcBridge.h"
#include "core/DesignTokens.h"
#include "shell/ShellWindowManager.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QLoggingCategory>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSocketNotifier>

#include <signal.h>
#include <sys/signalfd.h>
#include <unistd.h>

#include <memory>

namespace {

class ScopedFileDescriptor
{
public:
    explicit ScopedFileDescriptor(int descriptor = -1)
        : m_descriptor(descriptor)
    {
    }

    ~ScopedFileDescriptor()
    {
        if (m_descriptor >= 0)
            ::close(m_descriptor);
    }

    ScopedFileDescriptor(const ScopedFileDescriptor &) = delete;
    ScopedFileDescriptor &operator=(const ScopedFileDescriptor &) = delete;

    [[nodiscard]] int get() const noexcept
    {
        return m_descriptor;
    }

private:
    int m_descriptor = -1;
};

int createTerminationSignalFd()
{
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);

    if (::sigprocmask(SIG_BLOCK, &mask, nullptr) != 0)
        return -1;

    const int descriptor = ::signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (descriptor < 0)
        ::sigprocmask(SIG_UNBLOCK, &mask, nullptr);

    return descriptor;
}

} // namespace

int main(int argc, char *argv[])
{
    ScopedFileDescriptor terminationSignalFd(createTerminationSignalFd());

    QGuiApplication application(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("psd-shell"));
    QCoreApplication::setApplicationVersion(QStringLiteral("0.1.0"));
    QCoreApplication::setOrganizationName(QStringLiteral("SupraLINUX"));

    std::unique_ptr<QSocketNotifier> terminationNotifier;
    if (terminationSignalFd.get() >= 0) {
        terminationNotifier = std::make_unique<QSocketNotifier>(
            terminationSignalFd.get(), QSocketNotifier::Read, &application);

        QObject::connect(
            terminationNotifier.get(),
            &QSocketNotifier::activated,
            &application,
            [&application, descriptor = terminationSignalFd.get()](
                QSocketDescriptor, QSocketNotifier::Type) {
                signalfd_siginfo signalInfo{};
                while (::read(descriptor, &signalInfo, sizeof(signalInfo))
                       == static_cast<ssize_t>(sizeof(signalInfo))) {
                }
                application.quit();
            });
    } else {
        qWarning() << "PSD could not install SIGTERM/SIGINT shutdown handling";
    }

    DesignTokens designTokens;
    if (!designTokens.loaded()) {
        qCritical().noquote() << "PSD failed to load design tokens:"
                              << designTokens.errorString();
        return EXIT_FAILURE;
    }

    HyprlandIpcBridge compositorBridge;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("DesignTokens"), &designTokens);
    engine.rootContext()->setContextProperty(QStringLiteral("CompositorBridge"), &compositorBridge);

    ShellWindowManager shellWindows(&engine, &designTokens, &compositorBridge);

    compositorBridge.start();
    shellWindows.start();

    if (shellWindows.windowCount() == 0) {
        qCritical() << "PSD could not create a shell surface for any screen";
        return EXIT_FAILURE;
    }

    const int exitCode = application.exec();

    if (!shellWindows.shutdownCompositorSync())
        qWarning() << "PSD exited without confirming every compositor transform reset";

    return exitCode;
}
