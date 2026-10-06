import QtQuick
import Quickshell

// Launcher entry for Omaflow. Separate from the bar chip.
ShellRoot {
  Service {
    id: cooling
  }

  Standalone {
    service: cooling
    ownsProcess: true
  }
}
