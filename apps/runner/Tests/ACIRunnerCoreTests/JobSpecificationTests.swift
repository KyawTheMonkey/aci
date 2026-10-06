import ACIRunnerCore
import Foundation
import Testing

@Suite("Job specification")
struct JobSpecificationTests {
  @Test("A specification survives a JSON round trip")
  func roundTrip() throws {
    let original = makeJob(
      repository: makeRepository(),
      steps: [
        makeStep(
          arguments: ["hello"],
          environment: ["ACI_EXAMPLE": "value"],
          workingDirectory: "Sources"
        )
      ],
      artifacts: [ArtifactSpecification(path: "results.xcresult", required: true)]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JobSpecification.self, from: data)

    #expect(decoded == original)
  }
}
