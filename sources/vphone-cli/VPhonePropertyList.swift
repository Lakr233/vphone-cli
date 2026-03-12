import Foundation

enum VPhonePropertyList {
    static func load(from url: URL) throws -> (object: Any, format: PropertyListSerialization.PropertyListFormat) {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return (object, format)
    }

    static func rewriteXML(at url: URL) throws {
        let object = try load(from: url).object
        try write(object, to: url, format: .xml)
    }

    static func write(_ object: Any, to url: URL, format: PropertyListSerialization.PropertyListFormat = .xml) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        try data.write(to: url)
    }

    static func mutateDictionary(at url: URL, _ transform: (inout [String: Any]) throws -> Void) throws {
        var dictionary = (try load(from: url).object as? [String: Any]) ?? [:]
        try transform(&dictionary)
        try write(dictionary, to: url, format: .xml)
    }

    static func removeValue(at key: String, from url: URL) throws {
        try mutateDictionary(at: url) { dictionary in
            dictionary.removeValue(forKey: key)
        }
    }

    static func setBool(_ value: Bool, at key: String, in url: URL) throws {
        try mutateDictionary(at: url) { dictionary in
            dictionary[key] = value
        }
    }
}
