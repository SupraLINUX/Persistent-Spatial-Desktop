import QtQuick

Rectangle {
    id: center

    property bool returnEnabled: false
    signal requestCenter()

    radius: DesignTokens.value("radius.workspace")
    border.width: 1
    border.color: DesignTokens.value("colors.border.focused")
    clip: true

    gradient: Gradient {
        GradientStop {
            position: 0.0
            color: DesignTokens.value("colors.background.spatialBlue")
        }
        GradientStop {
            position: 0.58
            color: DesignTokens.value("colors.background.navy")
        }
        GradientStop {
            position: 1.0
            color: DesignTokens.value("colors.background.depthViolet")
        }
    }

    Rectangle {
        width: parent.width * 0.45
        height: width
        radius: width / 2
        x: parent.width * 0.54
        y: -height * 0.26
        color: DesignTokens.value("colors.accent.secondary")
        opacity: 0.12
    }

    Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 30
        spacing: 7

        Text {
            text: "CENTER"
            color: DesignTokens.value("colors.text.muted")
            font.pixelSize: 11
            font.weight: Font.Bold
            font.letterSpacing: 1.4
        }

        Text {
            text: "Desktop surface"
            color: DesignTokens.value("colors.text.primary")
            font.pixelSize: 24
            font.weight: Font.DemiBold
        }

        Text {
            text: "Qt/QML runtime bootstrap — compositor-owned application windows come next."
            color: DesignTokens.value("colors.text.secondary")
            font.pixelSize: 13
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: center.returnEnabled
        onClicked: center.requestCenter()
    }
}
