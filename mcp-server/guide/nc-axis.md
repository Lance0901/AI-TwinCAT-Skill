# nc-axis: Read before creating or configuring NC tasks and axes (AddNcTask, AddNcAxis, SetNcAxisParameter, LinkNcAxis).

## Steps
1. `AddNcTask` (one NC task per TINC; `NC_TASK_ALREADY_EXISTS` = use it).
2. `AddNcAxis` below `<NC task>^Axes` (simulation axis, encoder = Simulation encoder).
3. `SetNcAxisParameter` (max velocity, acceleration, deceleration, jerk, encoder / drive / controller type); every field is read back.
4. `LinkNcAxis` to the PLC `AXIS_REF` (NcToPlc <-> Outputs^ToPlc, PlcToNc <-> Inputs^FromPlc).
5. `BuildProject` -> activate (GetGuide('deploy')).

All four tools dry-run by default: read `data`, then call with `DryRun=false`. A real axis can move after Activate: the target must be confirmed (GetGuide('consent')).

## When it fails
Follow `error.hint`; a readback mismatch is a failure, do not retry with raw ConsumeXml. `IDE_MODAL_DIALOG`: GetGuide('open-project').
