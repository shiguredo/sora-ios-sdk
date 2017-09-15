import Foundation

struct JSONBuilder {
    
    var values: [String: AnyObject]
    
    func generate() -> String {
        return try! String(data: JSONSerialization.data(withJSONObject: self.values,
            options: JSONSerialization.WritingOptions(rawValue: 0)),
                           encoding: String.Encoding.utf8)!
    }
    
}

/*
public protocol JSONEncodable {
    
    func JSONRepresentation() -> String
    
}

func CreateJSONRepresentation(obj: AnyObject) -> String {
    return try! String(data: NSJSONSerialization.dataWithJSONObject(obj, options: NSJSONWritingOptions(rawValue: 0)),
                       encoding: NSUTF8StringEncoding)!
}


*/
