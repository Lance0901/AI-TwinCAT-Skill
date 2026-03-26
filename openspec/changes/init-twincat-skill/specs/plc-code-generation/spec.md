## ADDED Requirements

### Requirement: Generate Structured Text code from description
The system SHALL generate valid IEC 61131-3 Structured Text code based on natural language descriptions of the desired PLC logic.

#### Scenario: Generate motor control FB
- **WHEN** the user describes "a function block that controls a motor with start/stop, speed setpoint, and fault handling"
- **THEN** the system generates a complete FB_MotorControl with appropriate inputs (bStart, bStop, rSpeedSetpoint), outputs (bRunning, bFault), and internal logic in Structured Text

#### Scenario: Generate with Beckhoff library usage
- **WHEN** the generated code requires Beckhoff-specific library functions (e.g., Tc2_Standard timers, Tc3_Module)
- **THEN** the system includes the correct library function calls and notes which libraries must be referenced

### Requirement: Generate code following PLC best practices
The system SHALL generate code that follows established PLC programming best practices including state machines, proper error handling, and safe default states.

#### Scenario: State machine pattern
- **WHEN** the user requests logic with multiple operational states
- **THEN** the system generates a CASE-based state machine with explicit state enumeration and transition conditions

#### Scenario: Error handling pattern
- **WHEN** generating code that can encounter fault conditions
- **THEN** the system includes error state handling with fault latch and reset mechanisms

### Requirement: Inject generated code into IDE
The system SHALL write generated Structured Text code directly into POUs in the open TwinCAT project via IDE automation.

#### Scenario: Write code to existing POU
- **WHEN** a POU exists in the project and new code is generated for it
- **THEN** the system writes the declaration and implementation sections into the POU via COM automation

#### Scenario: Create POU and write code
- **WHEN** the target POU does not exist
- **THEN** the system first creates the POU then writes the generated code into it
