import QtQuick
import "Surfaces"

Item {
    id: root

    property real gutter: Math.max(12, Math.min(18, Math.min(width, height) * 0.012))
    property real leftWidth: Math.max(320, Math.min(460, width * 0.24))
    property real rightWidth: Math.max(340, Math.min(500, width * 0.26))
    property real topHeight: Math.max(220, Math.min(320, height * 0.25))
    property real centerWidth: width - (gutter * 2)
    property real centerHeight: height - (gutter * 2)
    property int spatialDuration: tokenNumber("motion.durationMs.spatial", 500)

    function tokenNumber(path, fallbackValue) {
        const value = DesignTokens.value(path)
        return value === undefined || value === null ? fallbackValue : Number(value)
    }

    function armEdge(destination) {
        if (SpatialState.currentSurface !== "center")
            return

        edgeTimer.destination = destination
        edgeTimer.restart()
    }

    function disarmEdge(destination) {
        if (edgeTimer.destination === destination)
            edgeTimer.stop()
    }

    property real worldX: {
        switch (SpatialState.currentSurface) {
        case "left": return leftWidth - gutter
        case "right": return -(rightWidth - gutter)
        default: return 0
        }
    }

    property real worldY: {
        switch (SpatialState.currentSurface) {
        case "top": return topHeight - gutter
        case "dash": return -(height - (gutter * 3))
        default: return 0
        }
    }

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
        x: root.worldX
        y: root.worldY

        Behavior on x {
            NumberAnimation {
                duration: root.spatialDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.22, 0.85, 0.26, 1.0, 1.0, 1.0]
            }
        }

        Behavior on y {
            NumberAnimation {
                duration: root.spatialDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: [0.22, 0.85, 0.26, 1.0, 1.0, 1.0]
            }
        }

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
            returnEnabled: SpatialState.currentSurface !== "center"
            onRequestCenter: SpatialState.center()
        }
    }

    Timer {
        id: edgeTimer
        property string destination: ""
        interval: 180
        repeat: false
        onTriggered: {
            if (SpatialState.currentSurface === "center")
                SpatialState.navigate(destination)
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
        enabled: SpatialState.currentSurface === "center"
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
        enabled: SpatialState.currentSurface === "center"
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
        enabled: SpatialState.currentSurface === "center"
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
        enabled: SpatialState.currentSurface === "center"
        onEntered: root.armEdge("dash")
        onExited: root.disarmEdge("dash")
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
            text: SpatialState.currentSurface.toUpperCase()
            color: DesignTokens.value("colors.text.secondary")
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
    }
}
