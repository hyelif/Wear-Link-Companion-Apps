import SwiftUI

struct DeviceInfoSection: View {
    var body: some View {
        List {
            infoRow(label: "Device Name", value: "Galaxy Watch7 (A64Y)")
            infoRow(label: "Device ID", value: "A64Y-7B3F-2C91")
            infoRow(label: "Product Name", value: "SM-R935")
            infoRow(label: "Model Name", value: "Galaxy Watch7")
            infoRow(label: "Android Version", value: "14")
            infoRow(label: "App Version", value: "1.0.0")
            infoRow(label: "Manufacturer", value: "Samsung")
            infoRow(label: "Battery Level", value: "85%")
            infoRow(label: "Is Charging", value: "No")
        }
        .navigationTitle("Device Information")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    NavigationStack {
        DeviceInfoSection()
    }
}
