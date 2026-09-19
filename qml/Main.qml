import QtQuick
import QtQuick.Window

Window {
    id: window

    width: 1280
    height: 800
    minimumWidth: 960
    minimumHeight: 600
    visible: false
    title: "Persistent Spatial Desktop — " + PsdScreenName
    color: DesignTokens.value("colors.background.deep")

    SpatialRoot {
        anchors.fill: parent
    }
}
