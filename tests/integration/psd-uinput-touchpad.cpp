#include <linux/input.h>
#include <linux/uinput.h>

#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <thread>
#include <unistd.h>

namespace {

constexpr int kMaxFingers = 4;
constexpr int kMaxX = 2000;
constexpr int kMaxY = 1200;
constexpr int kResolution = 40;

[[noreturn]] void fail(const std::string &message)
{
    throw std::runtime_error(message + ": " + std::strerror(errno));
}

void checkedIoctl(int fd, unsigned long request, int value, const char *label)
{
    if (ioctl(fd, request, value) < 0)
        fail(label);
}

void setupAbs(int fd, int code, int minimum, int maximum, int resolution = 0)
{
    uinput_abs_setup setup{};
    setup.code = code;
    setup.absinfo.minimum = minimum;
    setup.absinfo.maximum = maximum;
    setup.absinfo.resolution = resolution;

    if (ioctl(fd, UI_ABS_SETUP, &setup) < 0)
        fail("UI_ABS_SETUP");
}

void emitEvent(int fd, uint16_t type, uint16_t code, int32_t value)
{
    input_event event{};
    event.type = type;
    event.code = code;
    event.value = value;

    const auto written = write(fd, &event, sizeof(event));
    if (written != static_cast<ssize_t>(sizeof(event)))
        fail("write input event");
}

void sync(int fd)
{
    emitEvent(fd, EV_SYN, SYN_REPORT, 0);
}

int toolKeyForFingerCount(int fingers)
{
    switch (fingers) {
    case 1:
        return BTN_TOOL_FINGER;
    case 2:
        return BTN_TOOL_DOUBLETAP;
    case 3:
        return BTN_TOOL_TRIPLETAP;
    case 4:
        return BTN_TOOL_QUADTAP;
    default:
        throw std::runtime_error("unsupported finger count");
    }
}

struct Options
{
    int fingers = 4;
    int dx = 180;
    int dy = 0;
    int steps = 12;
    int preDelayMs = 1200;
    int durationMs = 180;
};

Options parseArgs(int argc, char **argv)
{
    Options options;

    auto nextInt = [&](int &index, const char *name) {
        if (index + 1 >= argc)
            throw std::runtime_error(std::string("missing value for ") + name);
        return std::stoi(argv[++index]);
    };

    for (int index = 1; index < argc; ++index) {
        const std::string arg = argv[index];
        if (arg == "--fingers")
            options.fingers = nextInt(index, "--fingers");
        else if (arg == "--dx")
            options.dx = nextInt(index, "--dx");
        else if (arg == "--dy")
            options.dy = nextInt(index, "--dy");
        else if (arg == "--steps")
            options.steps = nextInt(index, "--steps");
        else if (arg == "--pre-delay-ms")
            options.preDelayMs = nextInt(index, "--pre-delay-ms");
        else if (arg == "--duration-ms")
            options.durationMs = nextInt(index, "--duration-ms");
        else
            throw std::runtime_error("unknown argument: " + arg);
    }

    if (options.fingers < 1 || options.fingers > kMaxFingers)
        throw std::runtime_error("--fingers must be between 1 and 4");
    if (options.steps < 2)
        throw std::runtime_error("--steps must be at least 2");
    if (options.preDelayMs < 0 || options.durationMs < 1)
        throw std::runtime_error("invalid delay/duration");

    return options;
}

void setFingerCountKey(int fd, int fingers, bool down)
{
    emitEvent(fd, EV_KEY, toolKeyForFingerCount(fingers), down ? 1 : 0);
}

} // namespace

int main(int argc, char **argv)
{
    try {
        const Options options = parseArgs(argc, argv);

        const int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            fail("open /dev/uinput");

        checkedIoctl(fd, UI_SET_EVBIT, EV_SYN, "UI_SET_EVBIT EV_SYN");
        checkedIoctl(fd, UI_SET_EVBIT, EV_KEY, "UI_SET_EVBIT EV_KEY");
        checkedIoctl(fd, UI_SET_EVBIT, EV_ABS, "UI_SET_EVBIT EV_ABS");

        checkedIoctl(fd, UI_SET_KEYBIT, BTN_TOUCH, "UI_SET_KEYBIT BTN_TOUCH");
        checkedIoctl(fd, UI_SET_KEYBIT, BTN_LEFT, "UI_SET_KEYBIT BTN_LEFT");
        checkedIoctl(fd, UI_SET_KEYBIT, BTN_TOOL_FINGER, "UI_SET_KEYBIT BTN_TOOL_FINGER");
        checkedIoctl(fd, UI_SET_KEYBIT, BTN_TOOL_DOUBLETAP, "UI_SET_KEYBIT BTN_TOOL_DOUBLETAP");
        checkedIoctl(fd, UI_SET_KEYBIT, BTN_TOOL_TRIPLETAP, "UI_SET_KEYBIT BTN_TOOL_TRIPLETAP");
        checkedIoctl(fd, UI_SET_KEYBIT, BTN_TOOL_QUADTAP, "UI_SET_KEYBIT BTN_TOOL_QUADTAP");

        checkedIoctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER, "UI_SET_PROPBIT INPUT_PROP_POINTER");
        checkedIoctl(fd, UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD, "UI_SET_PROPBIT INPUT_PROP_BUTTONPAD");

        setupAbs(fd, ABS_X, 0, kMaxX, kResolution);
        setupAbs(fd, ABS_Y, 0, kMaxY, kResolution);
        setupAbs(fd, ABS_MT_SLOT, 0, kMaxFingers - 1);
        setupAbs(fd, ABS_MT_TRACKING_ID, 0, 65535);
        setupAbs(fd, ABS_MT_POSITION_X, 0, kMaxX, kResolution);
        setupAbs(fd, ABS_MT_POSITION_Y, 0, kMaxY, kResolution);

        uinput_setup device{};
        std::snprintf(device.name, UINPUT_MAX_NAME_SIZE, "PSD Virtual Touchpad");
        device.id.bustype = BUS_USB;
        device.id.vendor = 0x1209;
        device.id.product = 0x5053;
        device.id.version = 1;

        if (ioctl(fd, UI_DEV_SETUP, &device) < 0)
            fail("UI_DEV_SETUP");
        if (ioctl(fd, UI_DEV_CREATE) < 0)
            fail("UI_DEV_CREATE");

        std::cout << "PSD uinput touchpad: created fingers=" << options.fingers
                  << " dx=" << options.dx << " dy=" << options.dy << std::endl;

        std::this_thread::sleep_for(std::chrono::milliseconds(options.preDelayMs));

        int startX[kMaxFingers]{};
        int startY[kMaxFingers]{};

        for (int finger = 0; finger < options.fingers; ++finger) {
            startX[finger] = 700 + finger * 110;
            startY[finger] = 520 + (finger % 2) * 80;

            emitEvent(fd, EV_ABS, ABS_MT_SLOT, finger);
            emitEvent(fd, EV_ABS, ABS_MT_TRACKING_ID, 100 + finger);
            emitEvent(fd, EV_ABS, ABS_MT_POSITION_X, startX[finger]);
            emitEvent(fd, EV_ABS, ABS_MT_POSITION_Y, startY[finger]);
        }

        emitEvent(fd, EV_ABS, ABS_X, startX[0]);
        emitEvent(fd, EV_ABS, ABS_Y, startY[0]);
        emitEvent(fd, EV_KEY, BTN_TOUCH, 1);
        setFingerCountKey(fd, options.fingers, true);
        sync(fd);

        std::this_thread::sleep_for(std::chrono::milliseconds(60));

        for (int step = 1; step <= options.steps; ++step) {
            for (int finger = 0; finger < options.fingers; ++finger) {
                const int x = startX[finger] + (options.dx * step) / options.steps;
                const int y = startY[finger] + (options.dy * step) / options.steps;

                emitEvent(fd, EV_ABS, ABS_MT_SLOT, finger);
                emitEvent(fd, EV_ABS, ABS_MT_POSITION_X, x);
                emitEvent(fd, EV_ABS, ABS_MT_POSITION_Y, y);
            }

            emitEvent(fd, EV_ABS, ABS_X, startX[0] + (options.dx * step) / options.steps);
            emitEvent(fd, EV_ABS, ABS_Y, startY[0] + (options.dy * step) / options.steps);
            sync(fd);

            std::this_thread::sleep_for(
                std::chrono::milliseconds(options.durationMs / options.steps));
        }

        for (int finger = 0; finger < options.fingers; ++finger) {
            emitEvent(fd, EV_ABS, ABS_MT_SLOT, finger);
            emitEvent(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
        }

        setFingerCountKey(fd, options.fingers, false);
        emitEvent(fd, EV_KEY, BTN_TOUCH, 0);
        sync(fd);

        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        if (ioctl(fd, UI_DEV_DESTROY) < 0)
            fail("UI_DEV_DESTROY");

        close(fd);
        std::cout << "PSD uinput touchpad: gesture complete" << std::endl;
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "PSD uinput touchpad: " << error.what() << std::endl;
        return 1;
    }
}
