import Foundation
import os

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

enum CBMError: Error {
    case state(String)
    case permission(String)
    case timeout(String)
    case connection(String)
    case discovery(String)
    case io(String)
    case closed(String)
}

func cbmErrorTag(_ err: CBMError) -> Int32 {
    switch err {
    case .state:      return 1
    case .permission: return 2
    case .timeout:    return 3
    case .connection: return 4
    case .discovery:  return 5
    case .io:         return 6
    case .closed:     return 7
    }
}

func cbmErrorMessage(_ err: CBMError) -> String {
    switch err {
    case .state(let m), .permission(let m), .timeout(let m),
         .connection(let m), .discovery(let m), .io(let m), .closed(let m):
        return m
    }
}
