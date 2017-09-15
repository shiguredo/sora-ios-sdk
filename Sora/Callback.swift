import Foundation

public class BasicCallback<Param, Return> {
    
    fileprivate var repeats: Bool
    fileprivate var onExecuteHandler: ((Param) -> Return)?
    fileprivate var onThrowExecuteHandler: ((Param) throws -> Return)?
    fileprivate var onAfterHandler: (() -> Void)?
    
    public init(repeats: Bool) {
        self.repeats = repeats
    }
    
    public func clear() {
        onExecuteHandler = nil
        onThrowExecuteHandler = nil
        onAfterHandler = nil
    }
    
    public func execute(_ arg: Param) -> Return? {
        if let block = onExecuteHandler {
            let ret = block(arg)
            onAfterHandler?()
            if !repeats {
                clear()
            }
            return ret
        } else {
            return nil
        }
    }
    
    public func throwExecute(_ arg: Param) throws -> Return? {
        if let block = onThrowExecuteHandler {
            let ret = try block(arg)
            onAfterHandler?()
            if !repeats {
                clear()
            }
            return ret
        } else {
            return nil
        }
    }
    
    public func onExecute(handler: @escaping (Param) -> Return) {
        onExecuteHandler = handler
    }
    
    public func onThrowExecute(handler: @escaping (Param) throws -> Return) {
        onThrowExecuteHandler = handler
    }
    
    public func onAfter(handler: @escaping () -> Void) {
        onAfterHandler = handler
    }
    
}

public class Callback0<Return>: BasicCallback<(), Return> {
    
    public func execute() -> Return? {
        return super.execute(())
    }

    public override func onExecute(handler: @escaping () -> Return) {
        onExecuteHandler = handler
    }
    
    public override func onThrowExecute(handler: @escaping () throws -> Return) {
        onThrowExecuteHandler = handler
    }
    
}

public class Callback1<Param1,  Return>: BasicCallback<Param1, Return> {
}

public class Callback2<Param1, Param2, Return>: BasicCallback<(Param1, Param2), Return> {
    
    public func execute(_ arg1: Param1, _ arg2: Param2) -> Return? {
        return super.execute((arg1, arg2))
    }

    public override func onExecute(handler: @escaping (Param1, Param2) -> Return) {
        onExecuteHandler = { arg -> Return in
            let (arg1, arg2) = arg
            return handler(arg1, arg2)
        }
    }
    
}

public class Callback3<Param1, Param2, Param3, Return>: BasicCallback<(Param1, Param2, Param3), Return> {
    
    public func execute(_ arg1: Param1, _ arg2: Param2, _ arg3: Param3) -> Return? {
        return super.execute((arg1, arg2, arg3))
    }

    public override func onExecute(handler: @escaping (Param1, Param2, Param3) -> Return) {
        onExecuteHandler = { arg -> Return in
            let (arg1, arg2, arg3) = arg
            return handler(arg1, arg2, arg3)
        }
    }
    
}
