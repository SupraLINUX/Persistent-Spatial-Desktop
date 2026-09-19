import QtQuick
import "Surfaces"

Item {
    id: root

    property real gutter: SpatialLayout.gutter
    property real leftWidth: SpatialLayout.leftWidth
    property real rightWidth: SpatialLayout.rightWidth
    property real topHeight: SpatialLayout.topHeight
    property real centerWidth: SpatialLayout.centerWidth
    property real centerHeight: SpatialLayout.centerHeight

    function syncViewport() {
        SpatialLayout.viewportSize = Qt.size(width, height)
    }

    function armEdge(destination) {
        if (SpatialState.currentSurface !== "center" || SpatialMotion.running)
            return

        edgeTimer.destination = destination
        edgeTimer.restart()
    }

    function disarmEdge(destination) {
        if (edgeTimer.destination === destination)
            edgeTimer.stop()
    }

    Component.onCompleted: syncViewport()
    onWidthChanged: syncViewport()
    onHeightChanged: syncViewport()

    Rectangle {
        anchors.fill: parent
        color: DesignTokens.value("colors.background.deep")

        Rectangle {
            width: parent.width * 0.58
            height: width
            radius: width / 2
            x: -width * 0.35
            y: -height * 0.22
            color: DesignTokens.value("colors.background.deepViolet")
            opacity: 0.42
        }

        Rectangle {
            width: parent.width * 0.48
            height: width
            radius: width / 2
            x: parent.width - (width * 0.72)
            y: parent.height - (height * 0.62)
            color: DesignTokens.value("colors.background.spatialBlue")
            opacity: 0.28
        }
    }

    Item {
        id: world
        width: root.width
        height: root.height
        x: SpatialMotion.offsetX
        y: SpatialMotion.offsetY

        LeftSurface {
            x: -(root.leftWidth - root.gutter)
            y: root.gutter
            width: root.leftWidth
            height: root.centerHeight
        }

        RightSurface {
            x: root.width - root.gutter
            y: root.gutter
            width: root.rightWidth
            height: root.centerHeight
        }

        TopSurface {
            x: root.gutter
            y: -(root.topHeight - root.gutter)
            width: root.centerWidth
            height: root.topHeight
        }

        DashSurface {
            x: root.gutter
            y: root.height - root.gutter
            width: root.centerWidth
            height: root.centerHeight
        }

        CenterSurface {
            x: root.gutter
            y: root.gutter
            width: root.centerWidth
            height: root.centerHeight
            returnEnabled: SpatialState.currentSurface !== "center" && !SpatialMotion.running
            onRequestCenter: SpatialMotion.center()
        }
    }

    Timer {
        id: edgeTimer
        property string destination: ""
        interval: 180
        repeat: false
        onTriggered: {
            if (SpatialState.currentSurface === "center" && !SpatialMotion.running)
                SpatialMotion.navigate(destination)
        }
    }

    MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: root.gutter
        anchors.bottomMargin: root.gutter
        width: root.gutter
        z: 100
        hoverEnabled: true
        enabled: SpatialState.currentSurface === "center" && !SpatialMotion.running
        onEntered: root.armEdge("left")
        onExited: root.disarmEdge("left")
    }

    MouseArea {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: root.gutter
        anchors.bottomMargin: root.gutter
        width: root.gutter
        z: 100
        hoverEnabled: true
        enabled: SpatialState.currentSurface === "center" && !SpatialMotion.running
        onEntered: root.armEdge("right")
        onExited: root.disarmEdge("right")
    }

    MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: root.gutter
        anchors.rightMargin: root.gutter
        height: root.gutter
        z: 100
        hoverEnabled: true
        enabled: SpatialState.currentSurface === "center" && !SpatialMotion.running
        onEntered: root.armEdge("top")
        onExited: root.disarmEdge("top")
    }

    MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.gutter
        anchors.rightMargin: root.gutter
        height: root.gutter
        z: 100
        hoverEnabled: true
        enabled: SpatialState.currentSurface === "center" && !SpatialMotion.running
        onEntered: root.armEdge("dash")
        onExited: root.disarmEdge("dash")
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 24
        width: compositorStatus.implicitWidth + 24
        height: 30
        radius: 12
        color: "#9911192D"
        border.width: 1
        border.color: DesignTokens.value("colors.border.unfocused")
        z: 110

        Text {
            id: compositorStatus
            anchors.centerIn: parent
            text: {
                if (!CompositorBridge.available)
                    return "HYPRLAND · OFFLINE"

                const stream = CompositorBridge.eventStreamConnected ? "LIVE" : "IPC"
                const plugin = CompositorBridge.capabilities.spatialRenderOffsetExperimental ? " · PSD PLUGIN" : ""
                return "HYPRLAND · " + stream
                    + " · " + CompositorBridge.monitors.length + " MON"
                    + " · " + CompositorBridge.windows.length + " WIN"
                    + plugin
            }
            color: CompositorBridge.eventStreamConnected
                ? DesignTokens.value("colors.text.secondary")
                : DesignTokens.value("colors.text.muted")
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
    }

    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 24
        width: statusText.implicitWidth + 24
        height: 30
        radius: 12
        color: "#9911192D"
        border.width: 1
        border.color: DesignTokens.value("colors.border.unfocused")
        z: 110

        Text {
            id: statusText
            anchors.centerIn: parent
            text: (SpatialMotion.running ? SpatialMotion.targetSurface : SpatialState.currentSurface).toUpperCase()
            color: DesignTokens.value("colors.text.secondary")
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
    }
}
