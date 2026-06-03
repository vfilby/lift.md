import SwiftUI

struct GymDetailView: View {
    let gymId: String
    @Environment(GymStore.self) private var gymStore
    @Environment(EquipmentStore.self) private var equipmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingName = false
    @State private var gymName = ""
    @State private var showPresetSheet = false
    @State private var showDeleteConfirmation = false
    @State private var customEquipmentName = ""

    private var gym: Gym? {
        gymStore.gyms.first { $0.id == gymId }
    }

    var body: some View {
        List {
            if let gym {
                // Gym Info
                Section("Gym Information") {
                    if isEditingName {
                        HStack {
                            TextField("Gym Name", text: $gymName)
                                .accessibilityIdentifier("input-gym-name")
                            Button("Save") {
                                saveGymName()
                            }
                            .accessibilityIdentifier("save-gym-name")
                            Button("Cancel") {
                                isEditingName = false
                            }
                            .accessibilityIdentifier("cancel-edit-gym-name")
                        }
                    } else {
                        HStack {
                            Text(gym.name)
                            Spacer()
                            Button {
                                gymName = gym.name
                                isEditingName = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityIdentifier("edit-gym-name-button")
                        }
                    }

                    if !gym.isDefault {
                        Button {
                            gymStore.setDefault(id: gymId)
                        } label: {
                            Label("Set as Default", systemImage: "star")
                        }
                        .accessibilityIdentifier("set-default-button")
                    } else {
                        Label("Default Gym", systemImage: "star.fill")
                            .foregroundStyle(.secondary)
                    }
                }

                // Equipment
                Section("Equipment") {
                    ForEach(equipmentStore.equipment) { item in
                        HStack {
                            Text(item.name)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { item.isAvailable },
                                set: { _ in
                                    equipmentStore.toggleAvailability(id: item.id, gymId: gymId)
                                }
                            ))
                            .labelsHidden()
                            .accessibilityIdentifier("switch-equipment-\(item.id)")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                equipmentStore.removeEquipment(id: item.id, gymId: gymId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("equipment-item-\(item.id)")
                    }

                    // Custom equipment input
                    HStack {
                        TextField("Add custom equipment", text: $customEquipmentName)
                            .accessibilityIdentifier("input-custom-equipment")
                        Button {
                            addCustomEquipment()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(LiftMarkTheme.primary)
                        }
                        .disabled(customEquipmentName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("add-custom-equipment-button")
                    }

                    Button {
                        showPresetSheet = true
                    } label: {
                        Label("Add from Presets", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("preset-equipment-button")
                }

                // Danger Zone
                if gymStore.gyms.count > 1 {
                    Section("Danger Zone") {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Gym", systemImage: "trash")
                        }
                        .accessibilityIdentifier("delete-gym-button")
                    }
                }
            }
        }
        .accessibilityIdentifier("gym-detail-screen")
        .navigationTitle(gym?.name ?? "Gym")
        .onAppear {
            equipmentStore.loadEquipment(forGym: gymId)
        }
        .alert("Delete Gym", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                gymStore.deleteGym(id: gymId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this gym and all its equipment?")
        }
        .sheet(isPresented: $showPresetSheet) {
            PresetEquipmentSheet(gymId: gymId)
        }
    }

    private func saveGymName() {
        let trimmed = gymName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Update gym name via store (would need a rename method)
        // For now, the GymStore doesn't have updateGym, so we save the name directly
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE gyms SET name = ?, updated_at = ? WHERE id = ?",
                    arguments: [trimmed, now, gymId]
                )
            }
            gymStore.loadGyms()
        } catch {
            Logger.shared.error(.database, "Failed to rename gym", error: error)
        }
        isEditingName = false
    }

    private func addCustomEquipment() {
        let trimmed = customEquipmentName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        equipmentStore.addEquipment(name: trimmed, gymId: gymId)
        customEquipmentName = ""
    }
}

// MARK: - Preset Equipment Sheet

struct PresetEquipmentSheet: View {
    let gymId: String
    @Environment(EquipmentStore.self) private var equipmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPresets: Set<String> = []

    private var existingNames: Set<String> {
        Set(equipmentStore.equipment.map(\.name))
    }

    private let categories: [(name: String, items: [String])] = [
        ("Free Weights", PresetEquipment.freeWeights),
        ("Benches & Racks", PresetEquipment.benchesAndRacks),
        ("Machines", PresetEquipment.machines),
        ("Cardio", PresetEquipment.cardio),
        ("Other", PresetEquipment.other),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories, id: \.name) { category in
                    Section(category.name) {
                        ForEach(category.items, id: \.self) { item in
                            let isExisting = existingNames.contains(item)
                            HStack {
                                Text(item)
                                    .foregroundStyle(isExisting ? .secondary : .primary)
                                Spacer()
                                if isExisting {
                                    Text("Added")
                                        .font(.lmCaption)
                                        .foregroundStyle(.secondary)
                                } else if selectedPresets.contains(item) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LiftMarkTheme.primary)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isExisting else { return }
                                if selectedPresets.contains(item) {
                                    selectedPresets.remove(item)
                                } else {
                                    selectedPresets.insert(item)
                                }
                            }
                            .accessibilityIdentifier("preset-\(item)")
                        }
                    }
                }
            }
            .navigationTitle("Preset Equipment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedPresets.count))") {
                        addSelectedPresets()
                        dismiss()
                    }
                    .disabled(selectedPresets.isEmpty)
                }
            }
        }
    }

    private func addSelectedPresets() {
        for name in selectedPresets.sorted() {
            equipmentStore.addEquipment(name: name, gymId: gymId)
        }
    }
}
