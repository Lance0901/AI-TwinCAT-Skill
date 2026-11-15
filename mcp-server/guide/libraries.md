# libraries: Read before adding, removing, installing or freezing PLC libraries (GetLibraries, AddLibrary, AddPlaceholder, InstallLibrary, FreezePlaceholder).

## Steps
1. `GetLibraries` (references and placeholders; `Repository` = installed on this PC).
2. `AddLibrary Name Version Vendor` (`*` = newest installed) or `AddPlaceholder`.
3. `BuildProject`: `LIBRARY_UNRESOLVED` = a referenced library is not installed.
4. Not installed: `InstallLibrary` (dry-run first) changes this PC: ask the user first. `UninstallLibrary` too.
5. `FreezePlaceholder` pins a placeholder to its current version (dry-run first).

`RemoveReference` deletes a reference: ask the user first. `AllowUnresolvedLibrary=true` never makes a build complete; `EnableConfig` stays refused with BUILD_REQUIRED.
