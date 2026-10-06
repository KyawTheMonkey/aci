import ACISample
import Foundation
import XCTest

final class GreetingTests: XCTestCase {
  func testGreeting() {
    XCTAssertEqual(Greeting.message(for: "CI"), "Hello, CI!")
  }

  #if ACI_TEST_FAILURE
  func testIntentionalFailure() {
    XCTFail("Intentional failure used by the ACI acceptance harness.")
  }
  #endif

  #if ACI_TEST_TIMEOUT
  func testIntentionalTimeout() {
    Thread.sleep(forTimeInterval: 60)
  }
  #endif
}
