import Foundation
import Sora

class TestSuiteManager {
    
    static var shared: TestSuiteManager = TestSuiteManager()
    
    let saveFileName: String = "TestSuite.plist"

    var saveFilePath: URL? {
        get {
            if let dir = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask)
                .first {
                return dir.appendingPathComponent(saveFileName,
                                                  isDirectory: false)
            } else {
                return nil
            }
        }
    }
    
    var testSuite: TestSuite = TestSuite(testCases: [])
    
    var testCases: [TestCase] {
        get { return testSuite.testCases }
        set { testSuite.testCases = newValue }
    }

    var logText: String = ""
    weak var logViewController: LogViewController?
    
    var onAddHandler: ((TestCase) -> Void)?

    init() {
        Logger.shared.onOutputHandler = { log in
            DispatchQueue.main.async {
                self.logText.append(log.description)
                self.logText.append("\n")
                self.logViewController?.reloadData()
            }
        }
    }
    
    func clearLogText() {
        logText = ""
    }
    
    func load() {
        if let path = saveFilePath {
            print("load save file \(path)")
            if let testSuite = TestSuite(contentsOf: path) {
                self.testSuite = testSuite
            } else {
                print("failed to decode save file")
            }
        } else {
            print("create save file")
            testSuite = TestSuite(testCases: [])
            save()
        }
    }
    
    func save() {
        if let path = saveFilePath {
            testSuite.write(to: path)
        } else {
            print("save file path is not found")
        }
    }
    
    func save(block: (TestSuiteManager) -> Void) {
        block(self)
        save()
    }
    
    func add(testCase: TestCase) {
        testSuite.add(testCase: testCase)
        onAddHandler?(testCase)
    }
    
    func remove(testCase: TestCase) {
        testSuite.remove(testCase: testCase)
    }
    
    func remove(testCaseAt: Int) {
        testSuite.remove(testCaseAt: testCaseAt)
    }
    
    func insert(testCase: TestCase, at: Int) {
        testSuite.insert(testCase: testCase, at: at)
    }
    
}
