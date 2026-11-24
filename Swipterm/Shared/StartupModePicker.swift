import SwiftUI

struct StartupModePicker: View {
    @Binding var selection: ContainerInitMode

    var body: some View {
        Picker("Startup", selection: $selection) {
            Text(verbatim: "Init")
                .tag(ContainerInitMode.managed)
            Text(verbatim: "systemd")
                .tag(ContainerInitMode.system)
        }
    }
}
