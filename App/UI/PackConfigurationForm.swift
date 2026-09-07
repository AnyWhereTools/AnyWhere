import SwiftUI
import AnyWhereCore

struct PackConfigurationForm: View {
    let actionID: UUID
    let fields: [PackSetting]
    @State private var values: [String: String] = [:]
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "packConfig.title")).font(.system(size: 13, weight: .semibold))
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(field.title + (field.required == true ? " *" : ""))
                            .font(.system(size: 12)).frame(width: 110, alignment: .trailing)
                        input(field).frame(maxWidth: 320, alignment: .leading)
                    }
                    if let description = field.description, !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundStyle(AWColor.label2)
                            .padding(.leading, 122)
                    }
                }
            }
            HStack(spacing: 8) {
                AWButton(String(localized: "packConfig.save"), kind: .primary, size: .sm) { save() }
                    .disabled(!loaded)
                AWButton(String(localized: "packConfig.clear"), size: .sm) { clear() }
                    .disabled(!loaded)
                if !loaded {
                    AWButton(String(localized: "packConfig.retry"), size: .sm) { load() }
                }
            }
            if let message {
                Text(message).font(.system(size: 11))
                    .foregroundStyle(isError ? AWColor.red : AWColor.green)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AWColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AWColor.hairline, lineWidth: 0.5))
        .onAppear { load() }
    }

    private func binding(_ field: PackSetting) -> Binding<String> {
        Binding(get: { values[field.key] ?? field.initialValue }, set: {
            values[field.key] = $0
            message = nil
        })
    }

    @ViewBuilder private func input(_ field: PackSetting) -> some View {
        switch field.type {
        case .text:
            TextField(field.title, text: binding(field)).textFieldStyle(.roundedBorder)
        case .password:
            SecureField(field.title, text: binding(field)).textFieldStyle(.roundedBorder)
        case .toggle:
            Toggle(field.title, isOn: Binding(get: { binding(field).wrappedValue == "true" },
                                              set: { binding(field).wrappedValue = $0 ? "true" : "false" }))
                .labelsHidden().toggleStyle(.switch)
        case .select:
            Picker(field.title, selection: binding(field)) {
                Text(String(localized: "packConfig.unselected")).tag("")
                ForEach(field.options ?? [], id: \.self) { Text($0).tag($0) }
            }.labelsHidden()
        }
    }

    private func load() {
        do {
            values = try PackConfiguration.store().load(actionID: actionID, fields: fields)
            loaded = true; message = nil
        } catch { show(error) }
    }

    private func save() {
        do {
            try PackConfiguration.store().save(actionID: actionID, fields: fields, values: values)
            isError = false; message = String(localized: "packConfig.saved")
        } catch { show(error) }
    }

    private func clear() {
        do {
            try PackConfiguration.store().clear(actionID: actionID, fields: fields)
            values = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.initialValue) })
            isError = false; message = String(localized: "packConfig.cleared")
        } catch { show(error) }
    }

    private func show(_ error: Error) { isError = true; message = error.localizedDescription }
}
