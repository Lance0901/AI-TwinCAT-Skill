# variants: Read before reading or changing project variants (GetVariants, SetVariantConfig, SwitchVariant).

## Steps
1. `GetVariants`: current variant, variants, groups.
2. `SetVariantConfig` adds / removes variants (writes the whole ProjectVariantConfig back; backs up the .tsproj first).
3. `SwitchVariant` sets the current variant (case-sensitive; '[Group]' not activatable; '' clears it).
4. `BuildProject` -> activate (GetGuide('deploy')). The Boot package of a variant is compared under `_Boot\<Variant>\<platform>`.

Changing tools dry-run by default. `VARIANT_*` errors are raised before anything changed: follow `error.hint`.
