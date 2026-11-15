# tccom: Read before creating or parameterizing TcCOM module instances (AddTcComModule, SetTcComContext, GetTcComParameter, SetTcComParameter).

## Steps
1. `AddTcComModule` below `TIRC^TcCOM Objects` from the class GUID or type name; use the name XAE returns.
2. `SetTcComContext`: assign a task to the module context (TMC Context Id, not 0).
3. `GetTcComParameter` (offline from the project, or `Online=true` from the running object).
4. `SetTcComParameter`: into the project (then build + activate), or `Online=true` into the running object only.

All changing tools dry-run by default. `SetTcComParameter Online=true DryRun=false` changes the running runtime: on a target that is not `local-umrt` the tool asks the user in a confirmation form, and it is refused while the target has a lifecycle block (GetGuide('recovery')).
