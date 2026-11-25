import Foundation

enum KeyedArchiveParser {
    private static let uidSentinel = "__GLASSOTP_UID__"
    private static let maxArchiveBytes = 20 * 1024 * 1024
    private static let maxDepth = 64

    static func parseRoot(from data: Data) throws -> Any {
        guard data.count <= maxArchiveBytes else {
            throw OTPImportError.corruptedArchive("Archive exceeds maximum supported size.")
        }
        // Verify this looks like a property list before attempting deserialization
        guard let rawPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            throw OTPImportError.invalidFileFormat
        }

        // Convert to XML plist so CFKeyedArchiverUID entries serialize cleanly as <dict><key>CF$UID</key><integer>N</integer></dict>
        let xmlData = try PropertyListSerialization.data(fromPropertyList: rawPlist, format: .xml, options: 0)
        guard xmlData.count <= maxArchiveBytes * 2 else {
            throw OTPImportError.corruptedArchive("Archive XML representation exceeds maximum supported size.")
        }
        guard let xmlString = String(data: xmlData, encoding: .utf8) else {
            throw OTPImportError.corruptedArchive("Archive XML encoding failure.")
        }

        let rewrittenXML = xmlString.replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>\(uidSentinel)</key>")
        guard let rewrittenObj = try PropertyListSerialization.propertyList(
            from: Data(rewrittenXML.utf8),
            options: [],
            format: nil
        ) as? [String: Any],
              let top = rewrittenObj["$top"] as? [String: Any],
              let objects = rewrittenObj["$objects"] as? [Any],
              let rootRef = top["root"]
        else {
            throw OTPImportError.corruptedArchive("Missing NSKeyedArchiver $top/$objects header.")
        }

        var cache: [Int: Any] = [:]
        var active = Set<Int>()
        return try resolveValue(rootRef, objects: objects, cache: &cache, active: &active, depth: 0) ?? [String: Any]()
    }

    private static func uidIndex(from value: Any) -> Int? {
        guard let dict = value as? [String: Any], dict.count == 1, let rawIndex = dict[uidSentinel] else {
            return nil
        }
        if let intVal = rawIndex as? Int { return intVal }
        if let numVal = rawIndex as? NSNumber { return numVal.intValue }
        return nil
    }

    private static func resolveValue(
        _ value: Any,
        objects: [Any],
        cache: inout [Int: Any],
        active: inout Set<Int>,
        depth: Int
    ) throws -> Any? {
        guard depth <= maxDepth else {
            throw OTPImportError.corruptedArchive("Archive nesting exceeds safe depth.")
        }
        if let idx = uidIndex(from: value) {
            return try resolveObject(at: idx, objects: objects, cache: &cache, active: &active, depth: depth + 1)
        }
        if let arr = value as? [Any] {
            var resolved: [Any] = []
            resolved.reserveCapacity(arr.count)
            for item in arr {
                if let val = try resolveValue(item, objects: objects, cache: &cache, active: &active, depth: depth + 1) {
                    resolved.append(val)
                }
            }
            return resolved
        }
        if let dict = value as? [String: Any] {
            var resolved: [String: Any] = [:]
            for (k, v) in dict {
                if let val = try resolveValue(v, objects: objects, cache: &cache, active: &active, depth: depth + 1) {
                    resolved[k] = val
                }
            }
            return resolved
        }
        return value
    }

    private static func resolveObject(
        at index: Int,
        objects: [Any],
        cache: inout [Int: Any],
        active: inout Set<Int>,
        depth: Int
    ) throws -> Any? {
        guard depth <= maxDepth else {
            throw OTPImportError.corruptedArchive("Archive nesting exceeds safe depth.")
        }
        guard index > 0, index < objects.count else {
            return nil // index 0 is $null
        }
        if let cached = cache[index] {
            return cached
        }
        if active.contains(index) {
            return nil
        }
        active.insert(index)
        defer { active.remove(index) }

        let raw = objects[index]
        let result: Any?

        if let str = raw as? String {
            result = (str == "$null") ? nil : str
        } else if let dict = raw as? [String: Any] {
            if let nsString = dict["NS.string"] as? String {
                result = nsString
            } else if let nsData = dict["NS.data"] as? Data {
                result = nsData
            } else if let nsTime = dict["NS.time"] as? Double {
                result = Date(timeIntervalSinceReferenceDate: nsTime)
            } else if let nsKeys = dict["NS.keys"] as? [Any],
                      let nsObjects = dict["NS.objects"] as? [Any] {
                var unpacked: [String: Any] = [:]
                for (kRef, vRef) in zip(nsKeys, nsObjects) {
                    if let key = try resolveValue(kRef, objects: objects, cache: &cache, active: &active, depth: depth + 1) as? String,
                       let val = try resolveValue(vRef, objects: objects, cache: &cache, active: &active, depth: depth + 1) {
                        unpacked[key] = val
                    }
                }
                result = unpacked
            } else if let nsObjects = dict["NS.objects"] as? [Any] {
                var unpacked: [Any] = []
                unpacked.reserveCapacity(nsObjects.count)
                for item in nsObjects {
                    if let val = try resolveValue(item, objects: objects, cache: &cache, active: &active, depth: depth + 1) {
                        unpacked.append(val)
                    }
                }
                result = unpacked
            } else {
                var unpacked: [String: Any] = [:]
                for (k, v) in dict where k != "$class" {
                    if let val = try resolveValue(v, objects: objects, cache: &cache, active: &active, depth: depth + 1) {
                        unpacked[k] = val
                    }
                }
                if let classRef = dict["$class"],
                   let classDict = try resolveValue(classRef, objects: objects, cache: &cache, active: &active, depth: depth + 1) as? [String: Any],
                   let className = classDict["$classname"] as? String {
                    unpacked["__className__"] = className
                }
                result = unpacked
            }
        } else {
            result = raw
        }

        if let result {
            cache[index] = result
        }
        return result
    }
}
