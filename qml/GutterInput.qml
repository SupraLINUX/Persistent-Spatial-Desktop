import QtQuick
import QtQuick.Window

Window {
    id: gutterWindow

    property string destination: ""

    visible: false
    color: "transparent"
    title: "PSD Gutter — " + PsdScreenName + " — " + destination
    flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus

    Rectangle {
        anchors.fill: parent
        color: DesignTokens.value("colors.background.deep")
        opacity: 0.72
    }

    Rectangle {
        anchors.fill: parent
        color: DesignTokens.value("colors.border.unfocused")
        opacity: 0.18
    }

    Timer {
        id: dwellTimer
        interval: 180
        repeat: false
        onTriggered: {
            if (SpatialState.currentSurface === "center" && !SpatialMotion.running)
                SpatialMotion.navigate(gutterWindow.destination)
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        preventStealing: true
        enabled: SpatialState.currentSurface === "center" && !SpatialMotion.running

        onEntered: dwellTimer.restart()
        onExited: dwellTimer.stop()
        onPressed: mouse => {
            mouse.accepted = true
        }
    }
}
