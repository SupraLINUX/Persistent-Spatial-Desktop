import QtQuick
import QtQuick.Window

Window {
    id: shield

    visible: false
    color: "transparent"
    title: "PSD Return Shield — " + PsdScreenName

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        preventStealing: true
        onPressed: mouse => {
            mouse.accepted = true
            SpatialMotion.center()
        }
    }
}
