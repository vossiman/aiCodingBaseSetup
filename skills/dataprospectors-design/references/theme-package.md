# Shared theme contract

`@dataprospectors/themes` 0.1.0 is a private, CSS-first package. React is an
optional peer; CSS-only consumers need no React runtime. Build with
`npm run build -w @dataprospectors/themes` before packing or consuming JS.

In a Tailwind 4 application, load these imports in order:

```css
@import "tailwindcss";
@import "@dataprospectors/themes/fonts.css";
@import "@dataprospectors/themes/theme.css";
@import "@dataprospectors/themes/tailwind.css";
```

Without Tailwind, import fonts.css and theme.css only and use the semantic
CSS variables directly. These files supply no layout/reset styles.

## Root state

Use `data-brand="dataprospectors|customer"` and `data-theme="light|dark"`
on `<html>`. Missing attributes select dataprospectors/light. `applyTheme`
sets both attributes, synchronizes `.dark` and `style.colorScheme`, and
preserves other classes. `.dark` is also recognized by the CSS defaults.
Use a single root controller; explicit `data-theme` should agree with `.dark`.

```ts
import { applyTheme } from "@dataprospectors/themes";
applyTheme(document.documentElement, { brand: "customer", mode: "dark" });
applyTheme(document.documentElement); // dataprospectors/light
```

React consumers can use the optional `ThemeProvider` from
`@dataprospectors/themes/react` with `brand`, `mode` and `children` props.
One provider controls one document root. It applies state after mounting;
set matching root attributes in the initial HTML when first-paint theming
matters. Apps own state, persistence and OS preference policy.

## Customer overrides and assets

The `customer` preset is fictional Northstar. Load a customer stylesheet
**after** the package CSS. For both root selectors
`:root[data-brand="customer"][data-theme="light"]` and the dark equivalent,
override the complete semantic set in src/theme.css, plus `--brand-font`
and `--brand-mono` as required. Preserve token names; Tailwind utilities then
follow the same contract. Customer status and chart palettes need their own
accessibility review before adoption.

`brands` provides default names; consumers can supply their own
`BrandMetadata` (`name`, optional `lightLogo`/`darkLogo`) in the UI layer.
Asset URL resolution belongs to the consuming bundler:

```ts
import lightLogo from "@dataprospectors/themes/assets/dp-logo-light.png?url";
import darkLogo from "@dataprospectors/themes/assets/dp-logo-dark.png?url";
```

Select logo by its **surface**, not just mode: light mark on light surfaces,
dark mark on navy/dark surfaces. Northstar has a text wordmark. Fontsource
supplies local Archivo Variable and IBM Plex Mono; customers may override
family tokens. Package exports include all existing favicon/logo assets.

## Provenance and status

`references/` and `assets/` preserve the byte-identical 2026-09-30 import
from `/home/codespace/.claude/skills/dataprospectors-design/`. Native dataprospectors
token values are checked against that snapshot. The customer preset derives
from the reference's existing Northstar values, with missing semantic values
completed explicitly. Reference files remain compatibility/provenance inputs.

The theme package is the native integration foundation. The controls in
`apps/showroom` include upstream component examples and the retained theme-check
page. Adoption into a consuming application uses a checked dependency baseline.
The showroom's COMPATIBILITY.md and package-lock.json record the
selected dependency baseline. Versioned consumption and skill installation are documented in
[the consumption module](../modules/consumption.md).
