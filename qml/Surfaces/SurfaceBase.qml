import QtQuick

Rectangle {
    id: surface

    property string surfaceName: "SURFACE"
    property string purpose: ""
    property string summary: ""

    radius: DesignTokens.value("radius.workspace")
    color: "#CC11192D"
    border.width: 1
    border.color: DesignTokens.value("colors.border.default")
    clip: true

    Rectangle {
        anchors.fill: parent
        color: DesignTokens.value("colors.background.deepViolet")
        opacity: 0.12
    }

    Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 28
        spacing: 8

        Text {
            text: surface.surfaceName
            color: DesignTokens.value("colors.text.muted")
            font.pixelSize: 11
            font.weight: Font.Bold
            font.letterSpacing: 1.4
        }

        Text {
            text: surface.purpose
            color: DesignTokens.value("colors.text.primary")
            font.pixelSize: 24
            font.weight: Font.DemiBold
        }

        Text {
            width: Math.max(120, surface.width - 56)
            text: surface.summary
            wrapMode: Text.WordWrap
            color: DesignTokens.value("colors.text.secondary")
            font.pixelSize: 13
        }
    }
}
