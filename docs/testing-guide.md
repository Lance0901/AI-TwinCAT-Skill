# Automated PLC Testing Guide

## Overview

The TwinCATAutomation module provides a test framework that can:
1. Define test cases with setup, assertions, and teardown
2. Execute individual tests against a running PLC
3. Run full Build-Activate-Login-Run-Test cycles

## Defining Test Cases

```powershell
$test = New-TcTestCase -Name "Motor starts when enabled" `
    -Setup @(
        @{Path="GVL.bMotorEnable"; Value=$true}
    ) `
    -WaitMs 1000 `
    -Assertions @(
        @{Path="GVL.bMotorRunning"; Operator="IsTrue"},
        @{Path="GVL.nMotorSpeed"; Operator="GreaterThan"; Expected=0}
    ) `
    -Teardown @(
        @{Path="GVL.bMotorEnable"; Value=$false}
    )
```

## Assertion Operators

| Operator | Description | Example |
|----------|-------------|---------|
| Equal | Exact match | `@{Path="X"; Operator="Equal"; Expected=42}` |
| NotEqual | Not equal | `@{Path="X"; Operator="NotEqual"; Expected=0}` |
| GreaterThan | Greater than | `@{Path="X"; Operator="GreaterThan"; Expected=10}` |
| LessThan | Less than | `@{Path="X"; Operator="LessThan"; Expected=100}` |
| GreaterThanOrEqual | >= | `@{Path="X"; Operator="GreaterThanOrEqual"; Expected=0}` |
| LessThanOrEqual | <= | `@{Path="X"; Operator="LessThanOrEqual"; Expected=50}` |
| Contains | String contains | `@{Path="X"; Operator="Contains"; Expected="OK"}` |
| IsTrue | Boolean TRUE | `@{Path="X"; Operator="IsTrue"}` |
| IsFalse | Boolean FALSE | `@{Path="X"; Operator="IsFalse"}` |

## Running Individual Tests

```powershell
# Prerequisite: ADS connection must be active
Connect-TcAds

$result = Invoke-TcTest -TestCase $test
$result | ConvertTo-Json -Depth 5
```

## Running Full Test Cycles

```powershell
# Define multiple tests
$tests = @(
    (New-TcTestCase -Name "Test 1" -WaitMs 500 -Assertions @(@{Path="MAIN.x"; Operator="IsTrue"})),
    (New-TcTestCase -Name "Test 2" -WaitMs 500 -Assertions @(@{Path="MAIN.n"; Operator="Equal"; Expected=10}))
)

# Full cycle: Build -> Activate -> Login -> Run -> Test -> Stop
$report = Invoke-TcTestCycle -TestCases $tests
$report | ConvertTo-Json -Depth 5
```

## Test Report Format

```json
{
  "success": true,
  "data": {
    "timestamp": "2026-03-27T10:30:00.000+08:00",
    "durationMs": 5432,
    "total": 2,
    "passed": 2,
    "failed": 0,
    "steps": [
      {"step": "Build", "success": true},
      {"step": "Activate", "success": true},
      {"step": "Login", "success": true},
      {"step": "Run", "success": true},
      {"step": "Stop", "success": true}
    ],
    "results": [
      {
        "name": "Test 1",
        "result": "Pass",
        "durationMs": 520,
        "assertions": [{"path": "MAIN.x", "actual": true, "expected": "TRUE", "pass": true}]
      }
    ]
  }
}
```

## Monitoring Variables

```powershell
# Watch a variable for 5 seconds
Watch-TcVariable -Path "MAIN.nCounter" -IntervalMs 100 -DurationMs 5000

# Wait until a condition is met
Watch-TcVariable -Path "MAIN.bDone" -IntervalMs 50 -Until { $_.Value -eq $true } -TimeoutMs 10000
```
