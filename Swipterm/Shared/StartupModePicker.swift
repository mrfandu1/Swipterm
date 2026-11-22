import SwiftUI

struct StartupModePicker: View {
    @Binding var selection: ContainerInitMode
    let nativeInitSystem: NativeInitSystem?

    var body: some View {
        Picker("Startup", selection: $selection) {
            Text(verbatim: "Init")
                .tag(ContainerInitMode.managed)
            if let nativeInitSystem {
                Text(verbatim: nativeInitSystem.displayName)
                    .tag(ContainerInitMode.system)
            } else {
                Text("System Init")
                    .tag(ContainerInitMode.system)
            }
        }
    }
}
