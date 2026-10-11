import CoreData

/// Versioned interchange, rejecting partial decodes rather than silently losing bindings.
enum PresetCodec {
    enum Failure: Error { case invalidFormat, unsupportedVersion, duplicateID, incompleteDecode }
    static func encode(_ preset: Preset, envelope: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if envelope { return try encoder.encode(Document(format: "aom.preset", schemaVersion: 9, preset: preset)) }
        return try encoder.encode(preset)
    }
    private struct Document: Encodable { let format: String; let schemaVersion: Int; let preset: Preset }
    static func decode(_ data: Data) throws -> Preset {
        guard data.count <= 8_388_608, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidFormat }
        let raw: [String: Any]
        if root["schemaVersion"] != nil {
            guard root["format"] as? String == "aom.preset", [1, 2, 3, 4, 5, 6, 7, 8, 9].contains(root["schemaVersion"] as? Int ?? -1) else { throw Failure.unsupportedVersion }
            guard let value = root["preset"] as? [String: Any] else { throw Failure.invalidFormat }; raw = value
        } else { raw = root }
        guard let triggers = raw["triggers"] as? [[String: Any]], triggers.count <= 10000 else { throw Failure.invalidFormat }
        func checkDepth(_ actions: [[String: Any]], depth: Int) throws {
            guard depth <= 8, actions.count <= 1000 else { throw Failure.invalidFormat }
            for action in actions {
                if let params = action["parameters"] as? [String: Any] {
                    if let children = params["children"] as? [[String: Any]] { try checkDepth(children, depth: depth + 1) }
                    if let alternate = params["elseChildren"] as? [[String: Any]] { try checkDepth(alternate, depth: depth + 1) }
                }
            }
        }
        for trigger in triggers { try checkDepth(trigger["actions"] as? [[String: Any]] ?? [], depth: 0) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let preset = try decoder.decode(Preset.self, from: JSONSerialization.data(withJSONObject: raw))
        guard preset.triggers.count == triggers.count else { throw Failure.incompleteDecode }
        guard Set(preset.triggers.map(\.id)).count == preset.triggers.count,
              Set(preset.appTargets.map(\.id)).count == preset.appTargets.count,
              Set(preset.activationGroups.map(\.id)).count == preset.activationGroups.count else { throw Failure.duplicateID }
        guard preset.customSnapZones.count <= 32,
              Set(preset.customSnapZones.map(\.id)).count == preset.customSnapZones.count,
              preset.customSnapZones.allSatisfy(\.isValid) else { throw Failure.invalidFormat }
        guard preset.snapProfiles.count <= 16, preset.snapProfiles.allSatisfy(\.isValid),
              Set(preset.snapProfiles.map(\.id)).count == preset.snapProfiles.count,
              Set(preset.snapProfiles.map { $0.displayIDs.sorted() }).count == preset.snapProfiles.count else { throw Failure.invalidFormat }
        guard preset.activationGroups.count <= 64 else { throw Failure.invalidFormat }
        for group in preset.activationGroups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  group.name.count <= 128, group.includedBundleIDs.count <= 128,
                  group.excludedBundleIDs.count <= 128,
                  Set(group.includedBundleIDs).count == group.includedBundleIDs.count,
                  Set(group.excludedBundleIDs).count == group.excludedBundleIDs.count,
                  (group.includedBundleIDs + group.excludedBundleIDs).allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else { throw Failure.invalidFormat }
        }
        let groupIDs = Set(preset.activationGroups.map(\.id))
        for trigger in preset.triggers {
            guard (100...2000).contains(trigger.sequenceMaxGapMs),
                  (0...5000).contains(trigger.sequenceHoldMs) else { throw Failure.invalidFormat }
            if case .drawingPattern = trigger.input {
                guard trigger.drawingCertainty.isFinite, (0.50...0.90).contains(trigger.drawingCertainty) else { throw Failure.invalidFormat }
                guard !trigger.drawingSamples.isEmpty, trigger.drawingSamples.count <= 3,
                      trigger.drawingSamples.allSatisfy({ sample in
                          (8...256).contains(sample.count) && sample.allSatisfy {
                              $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
                          }
                      }) else { throw Failure.invalidFormat }
            }
            if case .keySequence(let strokes) = trigger.input {
                guard (1...6).contains(strokes.count),
                      (trigger.sequenceHoldMs == 0 || (strokes.count == 1 && trigger.sequenceHoldMs >= 300)) else { throw Failure.invalidFormat }
            }
            if let id = trigger.activationGroupID {
                guard groupIDs.contains(id), trigger.appBundleID == nil else { throw Failure.invalidFormat }
            }
            guard (100...60000).contains(trigger.holdDelayMs), (50...60000).contains(trigger.holdIntervalMs), ActionTree.problem(trigger.actions) == nil else { throw Failure.invalidFormat }
        }
        return preset
    }
}

/// A normalized Core Data graph for trackpad bindings. Other input families
/// remain opaque in metadata, so migration cannot reinterpret their settings.
/// Recognition only consumes the existing immutable value snapshot, never a
/// managed object or database fetch on a contact callback.
final class TrackpadPresetStore {
    private let context: NSManagedObjectContext
    init(url: URL?, inMemory: Bool = false) throws {
        let model = Self.model()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: inMemory ? NSInMemoryStoreType : NSSQLiteStoreType,
            configurationName: nil, at: url, options: [NSMigratePersistentStoresAutomaticallyOption: true,
                                                      NSInferMappingModelAutomaticallyOption: true])
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator; context.undoManager = nil
    }
    private static func model() -> NSManagedObjectModel {
        func entity(_ name: String, _ fields: [(String, NSAttributeType)]) -> NSEntityDescription {
            let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"
            e.properties = fields.map { name, type in
                let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = false; return a
            }; return e
        }
        let root = entity("TrackpadPreset", [("metadata", .binaryDataAttributeType), ("schemaVersion", .integer16AttributeType)])
        let app = entity("ApplicationScope", [("id", .UUIDAttributeType), ("name", .stringAttributeType), ("bundleID", .stringAttributeType)])
        let gesture = entity("GestureBinding", [("id", .UUIDAttributeType), ("kind", .stringAttributeType), ("position", .integer64AttributeType), ("template", .binaryDataAttributeType)])
        let action = entity("OrderedAction", [("id", .UUIDAttributeType), ("kind", .stringAttributeType), ("position", .integer64AttributeType), ("enabled", .booleanAttributeType), ("parameters", .binaryDataAttributeType)])
        let shortcut = entity("ActionShortcut", [("keyCode", .integer32AttributeType), ("modifiers", .stringAttributeType)])
        func relationship(_ owner: NSEntityDescription, _ name: String, _ child: NSEntityDescription, _ inverse: String, many: Bool, cascade: Bool) {
            let a = NSRelationshipDescription(); a.name = name; a.destinationEntity = child; a.minCount = 0; a.maxCount = many ? 0 : 1; a.isOptional = true
            a.deleteRule = cascade ? .cascadeDeleteRule : .nullifyDeleteRule
            let b = NSRelationshipDescription(); b.name = inverse; b.destinationEntity = owner; b.minCount = 0; b.maxCount = 1; b.isOptional = true; b.deleteRule = .nullifyDeleteRule
            a.inverseRelationship = b; b.inverseRelationship = a; owner.properties.append(a); child.properties.append(b)
        }
        relationship(root, "applications", app, "preset", many: true, cascade: true)
        relationship(root, "gestures", gesture, "preset", many: true, cascade: true)
        relationship(app, "gestures", gesture, "application", many: true, cascade: false)
        relationship(gesture, "actions", action, "gesture", many: true, cascade: true)
        relationship(action, "shortcut", shortcut, "action", many: false, cascade: true)
        let model = NSManagedObjectModel(); model.entities = [root, app, gesture, action, shortcut]; model.versionIdentifiers = ["AOMTrackpadV1"]
        return model
    }
    func flushPendingWrites() { context.performAndWait {} }
    func save(_ preset: Preset) throws { try context.performAndWait { try replace(preset) } }
    func saveAsync(_ preset: Preset) {
        context.perform {
            do { try self.replace(preset) }
            catch { self.context.rollback(); NSLog("[AOM] Trackpad database save failed: %@", error.localizedDescription) }
        }
    }
    private func replace(_ preset: Preset) throws {
        // Validate before changing the existing graph. A transaction either
        // replaces all app/gesture/action rows or keeps the previous snapshot.
        _ = try PresetCodec.decode(PresetCodec.encode(preset))
        do {
            for old in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TrackpadPreset")) { context.delete(old) }
            func insert(_ name: String) -> NSManagedObject { NSEntityDescription.insertNewObject(forEntityName: name, into: context) }
            let root = insert("TrackpadPreset"); root.setValue(1, forKey: "schemaVersion")
            var metadata = preset; metadata.triggers = preset.triggers.filter { $0.input.category != .trackpad }
            root.setValue(try PresetCodec.encode(metadata), forKey: "metadata")
            var scopes: [String: NSManagedObject] = [:]
            for target in preset.appTargets {
                let app = insert("ApplicationScope"); app.setValue(target.id, forKey: "id"); app.setValue(target.name, forKey: "name"); app.setValue(target.bundleID ?? "", forKey: "bundleID"); app.setValue(root, forKey: "preset")
                scopes[target.bundleID ?? ""] = app
            }
            let encoder = JSONEncoder()
            for (position, trigger) in preset.triggers.enumerated() {
                guard case .trackpadGesture(let kind) = trigger.input else { continue }
                let record = insert("GestureBinding"); record.setValue(trigger.id, forKey: "id"); record.setValue(kind.rawValue, forKey: "kind"); record.setValue(position, forKey: "position")
                var template = trigger; template.actions = []
                record.setValue(try encoder.encode(template), forKey: "template"); record.setValue(root, forKey: "preset")
                record.setValue(scopes[trigger.appBundleID ?? ""], forKey: "application")
                for (order, value) in trigger.actions.enumerated() {
                    let action = insert("OrderedAction"); action.setValue(value.id, forKey: "id"); action.setValue(value.actionType.rawValue, forKey: "kind"); action.setValue(order, forKey: "position"); action.setValue(value.isEnabled, forKey: "enabled"); action.setValue(record, forKey: "gesture")
                    var params = value.parameters
                    if let code = params.shortcutKeyCode {
                        let key = insert("ActionShortcut"); key.setValue(Int(code), forKey: "keyCode"); key.setValue(params.shortcutModifiers.map(String.init) ?? "", forKey: "modifiers"); key.setValue(action, forKey: "action")
                        params.shortcutKeyCode = nil; params.shortcutModifiers = nil
                    }
                    action.setValue(try encoder.encode(params), forKey: "parameters")
                }
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func load() throws -> Preset? {
        try context.performAndWait {
            guard let root = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "TrackpadPreset")).first else { return nil }
            guard root.value(forKey: "schemaVersion") as? Int == 1, let metadata = root.value(forKey: "metadata") as? Data else { throw PresetCodec.Failure.unsupportedVersion }
            var preset = try PresetCodec.decode(metadata)
            let decoder = JSONDecoder()
            let records = (root.value(forKey: "gestures") as? Set<NSManagedObject> ?? []).sorted { ($0.value(forKey: "position") as! Int) < ($1.value(forKey: "position") as! Int) }
            for record in records {
                var trigger = try decoder.decode(Trigger.self, from: record.value(forKey: "template") as! Data)
                let actions = (record.value(forKey: "actions") as? Set<NSManagedObject> ?? []).sorted { ($0.value(forKey: "position") as! Int) < ($1.value(forKey: "position") as! Int) }
                trigger.actions = try actions.map { row in
                    guard let type = ActionType(rawValue: row.value(forKey: "kind") as! String) else { throw PresetCodec.Failure.incompleteDecode }
                    var params = try decoder.decode(ActionParameters.self, from: row.value(forKey: "parameters") as! Data)
                    if let key = row.value(forKey: "shortcut") as? NSManagedObject {
                        params.shortcutKeyCode = UInt16(key.value(forKey: "keyCode") as! Int); params.shortcutModifiers = UInt(key.value(forKey: "modifiers") as! String)
                    }
                    // Decode through the public Codable representation to preserve immutable IDs.
                    let payload: [String: Any] = ["id": (row.value(forKey: "id") as! UUID).uuidString, "actionType": type.rawValue,
                        "isEnabled": row.value(forKey: "enabled") as! Bool, "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(params))]
                    return try decoder.decode(TriggerAction.self, from: JSONSerialization.data(withJSONObject: payload))
                }
                let position = record.value(forKey: "position") as! Int
                preset.triggers.insert(trigger, at: min(position, preset.triggers.count))
            }
            return try PresetCodec.decode(PresetCodec.encode(preset))
        }
    }
}
