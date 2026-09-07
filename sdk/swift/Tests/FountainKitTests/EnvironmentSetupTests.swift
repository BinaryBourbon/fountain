import Foundation
import Testing
@testable import FountainKit

@Test func environmentSetupTimeoutRoundTrips() throws {
  let input = EnvironmentInput(name: "reviewer", setupTimeoutSeconds: 900)
  let encoded = try JSONEncoder().encode(input)
  let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
  #expect(json["setup_timeout_seconds"] as? Int == 900)

  let payload = Data(#"{"id":"env","name":"reviewer","setup_timeout_seconds":900}"#.utf8)
  let environment = try JSONDecoder().decode(FountainKit.Environment.self, from: payload)
  #expect(environment.setupTimeoutSeconds == 900)
  let older = Data(#"{"id":"env","name":"reviewer"}"#.utf8)
  #expect(try JSONDecoder().decode(FountainKit.Environment.self, from: older).setupTimeoutSeconds == nil)
}
