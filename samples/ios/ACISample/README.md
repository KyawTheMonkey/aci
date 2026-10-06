# ACI iOS Sample

This dependency-free Swift package is the real iOS workload used by the local runner acceptance harness. Xcode builds the package for an installed iOS Simulator and runs its XCTest target.

The source includes compile-time switches used only by the negative acceptance scenarios:

- `ACI_COMPILE_FAILURE` introduces a Swift type error.
- `ACI_TEST_FAILURE` enables an intentionally failing XCTest.
- `ACI_TEST_TIMEOUT` enables a long-running XCTest.

Run the success scenario from the repository root:

```bash
./scripts/verify-runner-ios.sh
```

Run the success case and the expected failure matrix:

```bash
./scripts/verify-runner-ios.sh --all
```
