import Foundation

/// A deliberately small API used by the runner's iOS acceptance job.
public enum Greeting {
  public static func message(for name: String) -> String {
    "Hello, \(name)!"
  }
}

#if ACI_COMPILE_FAILURE
private let intentionallyInvalidValue: String = 42
#endif
