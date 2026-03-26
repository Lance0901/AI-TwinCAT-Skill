## ADDED Requirements

### Requirement: Define test cases
The system SHALL support defining test cases as JSON or PowerShell objects. Each test case SHALL specify: a name, optional setup actions (variable writes), a wait condition or duration, assertion checks (variable reads with expected values), and optional teardown actions.

#### Scenario: Simple variable assertion test
- **WHEN** the user calls `New-TcTestCase -Name "Counter increments" -Assertions @{Path="MAIN.nCounter"; Operator="GreaterThan"; Expected=0} -WaitMs 1000`
- **THEN** the system creates a test case definition that waits 1 second then checks if MAIN.nCounter > 0

#### Scenario: Test with setup and teardown
- **WHEN** the user defines a test with `-Setup @{Path="MAIN.bStart"; Value=$true}` and `-Teardown @{Path="MAIN.bStart"; Value=$false}`
- **THEN** the system creates a test case that writes bStart=TRUE before testing and bStart=FALSE after

### Requirement: Execute test cases
The system SHALL execute test cases against a running PLC and return pass/fail results. The `Invoke-TcTest` cmdlet SHALL handle the full sequence: apply setup, wait, read variables, evaluate assertions, apply teardown.

#### Scenario: Single test passes
- **WHEN** `Invoke-TcTest` runs a test and all assertions pass
- **THEN** the system returns `{"success": true, "data": {"name": "Counter increments", "result": "Pass", "assertions": [{"path": "MAIN.nCounter", "actual": 5, "expected": ">0", "pass": true}]}}`

#### Scenario: Single test fails
- **WHEN** `Invoke-TcTest` runs a test and an assertion fails
- **THEN** the system returns `{"success": true, "data": {"name": "Counter increments", "result": "Fail", "assertions": [{"path": "MAIN.nCounter", "actual": 0, "expected": ">0", "pass": false}]}}`

#### Scenario: Test timeout
- **WHEN** a test's wait condition is not met within the specified timeout
- **THEN** the system returns a Fail result with reason `TIMEOUT`

### Requirement: Execute full test-build-run cycle
The system SHALL provide a single cmdlet `Invoke-TcTestCycle` that runs the complete cycle: Build → Activate → Login → Run → Execute Tests → Collect Results → Stop.

#### Scenario: Full cycle succeeds
- **WHEN** the user calls `Invoke-TcTestCycle -TestCases $tests`
- **THEN** the system builds the project, activates configuration, logs in, starts the PLC, runs all test cases, collects results, stops the PLC, and returns a summary report

#### Scenario: Build fails during cycle
- **WHEN** `Invoke-TcTestCycle` encounters a build error
- **THEN** the system stops the cycle immediately and returns the build errors without attempting activation or testing

#### Scenario: Partial test failures
- **WHEN** some tests pass and some fail during the cycle
- **THEN** the system completes all tests and returns a summary with total/passed/failed counts plus individual results

### Requirement: Test report generation
The system SHALL generate a structured test report in JSON format after test execution, suitable for CI/CD integration or AI tool interpretation.

#### Scenario: Generate test report
- **WHEN** test execution completes
- **THEN** the system returns a report containing: timestamp, project name, total tests, passed, failed, duration, and detailed results per test case

### Requirement: Assertion operators
The system SHALL support the following assertion operators: `Equal`, `NotEqual`, `GreaterThan`, `LessThan`, `GreaterThanOrEqual`, `LessThanOrEqual`, `Contains`, `IsTrue`, `IsFalse`.

#### Scenario: Equality assertion
- **WHEN** an assertion specifies `Operator="Equal"` and `Expected=42`
- **THEN** the test passes if the actual variable value equals 42

#### Scenario: Boolean assertion
- **WHEN** an assertion specifies `Operator="IsTrue"`
- **THEN** the test passes if the actual variable value is TRUE
