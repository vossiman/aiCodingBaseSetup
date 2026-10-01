---
title: Legacy patterns and native shadcn coverage
status: done
created: 2026-10-01
---

# Legacy patterns and native shadcn coverage

Use this selection aid to start with native components and consult the legacy
reference for useful additional behavior. It is a representative source assessment
of the baseline merged in PR #4 (`67d60b0`), not an adoption decision or migration
queue. Follow the [demand-driven strategy](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/docs/specs/active/2026-09-30-demand-driven.md):
reuse suitable production components first, then compatible standard shadcn, then
justify specialist or custom work against an actual selected feature.

## Scope and evidence

The [legacy catalogue](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/showroom/catalog.json)
retains all 234 pages. The [native inventory](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/catalog/inventory.ts)
and [coverage manifest](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/catalog/coverage.json) describe
64 families/compositions and 246 panels. This map groups representative patterns;
it does not assess every page, variant or dependency API.

Links below open repository source, so they work without a deployment. To try an
example, use the legacy route printed beside it or native `#/components/<family>`
with the [paired preview](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/README.md#native-and-legacy-showrooms). Native
sources link to the demonstrated implementation, not merely a matching name.

**Covered** means the inspected standard capability has a native implementation.
**Composable** means native primitives supply the UI but application state,
semantics or layout must be assembled. **Potential gap** means the native
showroom does not demonstrate the stated specialist capability; it does not
prove the underlying dependencies cannot supply it. Each gap requires feature
requirements and evidence before choosing a library or custom component.

Inspection covered entry pages and the linked implementation files, native
wrappers/examples and provenance. No fresh interactive, screen-reader or
performance audit was performed for this document. Keyboard expectations below
are acceptance checks for a selected feature, not certification of either demo.

## Standard coverage

| Pattern and legacy representative | Native counterpart | Assessment and selection boundary |
| --- | --- | --- |
| Modal and offcanvas interaction: [modals](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/ui/modals/index.tsx), `/ui/modals` | [Dialog](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/components/ui/dialog.tsx), [Sheet](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/overlays/sheet.tsx) | **Covered** for modal content and edge panels. Legacy adds positioned, fullscreen and stacked examples; use native sizing/state composition if selected. Check accessible title, trapped focus, Escape/dismiss policy and focus return, especially with multiple overlays. |
| Local content tabs: [tabs](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/ui/tabs/index.tsx), `/ui/tabs` | [Tabs](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/navigation/tabs.tsx) | **Covered** for switching local panels. Legacy's vertical, justified, colored and card variants mainly add layout ideas. Check arrow navigation, orientation and selected-panel relationships after styling. |
| Toast feedback: [notifications](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/ui/notifications/index.tsx), `/ui/notifications` | [Sonner](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/feedback/sonner.tsx) | **Covered** for transient notifications/actions. Legacy adds branded headers, timestamps and placement examples; these do not establish a notification history service. Check announcements, dismiss/action keyboard access and suitable duration. |
| Searchable and grouped option selection: [Select2 example](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/select/components/Select2.tsx), `/form/select` | [Combobox](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/components/ui/combobox.tsx), [examples](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/forms/combobox.tsx) | **Covered** for standard option search; native source also exposes groups/chips. The legacy example actually uses [react-select](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/components/wrappers/Select.tsx), despite its Select2/jQuery description. Multi-selection needs a feature-specific composition/check; remote search and infinite results are described but not demonstrated by that legacy file. Check labels, arrow/Enter/Escape behavior and chip removal. |
| Single date and date range selection: [pickers](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/pickers/components/Pickers.tsx), `/form/pickers` | [Date range](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/date-picker-with-range.tsx), [Date Picker panels](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/forms/date-picker.tsx) | **Covered** for choosing dates/ranges, using Calendar and Popover. Legacy additionally configures time selection and date restrictions; do not infer equivalent date-time/timezone behavior from the date-only demo. Check grid keyboard use, disabled dates, format and locale for the feature. |

## Native compositions

| Pattern and legacy representative | Native starting point | Assessment and extra legacy value |
| --- | --- | --- |
| Sortable/filterable record list: [export table](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/tables/datatables/export-data/components/ExportDataWithButtons.tsx), `/tables/datatables/export-data` | [Data Table](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/data-table-demo.tsx) | **Composable** for a record workflow; native demo already combines TanStack sorting, email filtering, row selection, column visibility, empty state and pagination. Legacy adds CSV/Excel/PDF/copy export, outside that demo. Define server paging, export scope and scale before extending it; verify sort announcements and labeled selection/actions. No spreadsheet-style grid keyboard model is implied. |
| Validated multi-step form: [wizard](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/wizard/components/WizardWithValidation.tsx), `/form/wizard` | [RHF form](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/form-rhf-demo.tsx), [Progress](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/feedback/progress.tsx) and Button | **Composable** with step state and per-step validation. Legacy offers a five-step flow; native has no ready wizard composition. Define back/next, retained values, submission and error focus; announce step changes and associate field errors. Tabs alone would not enforce progression. |
| Activity timeline: [timeline](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/pages/timeline/index.tsx), `/pages/timeline` | [Item](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/data-display/item.tsx), Avatar, Separator and semantic list markup | **Composable** for chronological activity. Legacy offers timestamps, authors and icon/border layouts. Native has no timeline demo; application ordering/grouping and connector CSS remain to build. Preserve reading order and textual status rather than relying on color. |
| Responsive application navigation: [offcanvas layout](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/layouts/sidebar-offcanvas/index.tsx), `/layouts/sidebar-offcanvas` | [Sidebar example](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/local-sidebar-states.tsx), Sheet and Breadcrumb | **Composable** for an application shell. Native demonstrates collapse and active selection; legacy offers shell configuration variants. Routing, permissions and full responsive layout are application work. Check landmark labels, active links, mobile focus return and narrow-screen overflow. |
| Conversation view: [ChatPage](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/apps/chat/components/ChatPage.tsx), `/apps/chat` | [Message example](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/local-message-states.tsx), Bubble and Message Scroller | **Composable** for conversation presentation and local input. Legacy adds contact/conversation layout; its send control is not evidence of a transport. Native appends local messages only. Delivery, history and unread behavior need feature requirements; check new-message announcements and scroll/focus behavior. |
| Ordinary business charts: [bar charts](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/charts/apex/bar/components/BarChart.tsx), `/charts/apex/bar` | [Chart panels](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/data-display/chart.tsx) | **Composable** for dashboards using the native bar/line/area/pie baseline and shared palette. Legacy adds numerous chart configurations; specialized financial rendering is a potential gap below. Define data/labels and provide a textual alternative; richer legacy chart types need separate assessment. |

## Potential specialist or custom gaps

The native links here show the closest UI building blocks, **not equivalents**.
Legacy dependencies name inspected implementations, not recommended dependencies
for a consumer. Reuse them only after compatibility and maintenance review.

| Capability and inspected legacy example | Native boundary | What would justify further work |
| --- | --- | --- |
| Drag/drop files and image processing: [Dropzone](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/fileuploads/components/Dropzone.tsx), [FilePond](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/fileuploads/components/FilePondUploader.tsx), `/form/fileuploads` | [Attachment states](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/examples/local-attachment-states.tsx) display files and simulated states; they do not ingest or upload files. | A selected upload flow needing drop handling, limits, previews, reorder or EXIF processing. FilePond's `/api` setting is not evidence of a working server. Verify keyboard file selection, errors, cancellation and real processing/transport separately. |
| Rich text editing: [Quill example](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/text-editors/components/SnowEditor.tsx), `/form/text-editors` | [Textarea](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/forms/textarea.tsx) and toolbar primitives do not supply a document editing engine. | Required formatted content, links/media and a storage format. Decide document schema, paste/sanitization and toolbar/editor keyboard behavior before selecting an engine. |
| Event scheduling: [CalendarPage](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/apps/calendar/components/CalendarPage.tsx), `/apps/calendar` | [Calendar](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/forms/calendar.tsx) selects dates; Dialog can host event forms. | Required event views and moving/editing events. Legacy uses FullCalendar day/time/list and interaction plugins with local state. Define timezone, recurrence, persistence and a keyboard alternative to dragging; recurrence is not established by this inspection. |
| Board drag/drop: [Board](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/apps/projects/kanban/components/Board.tsx), `/apps/projects/kanban` | [Card](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/layout/card.tsx) and Scroll Area cover presentation, not drag sensors or reorder semantics. | A selected board needing cross-column moves/reorder; legacy uses `@hello-pangea/dnd`. A button/menu move flow may suffice. Verify keyboard moves, announcements, undo and persisted ordering. |
| Interactive hierarchy: [Treeview](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/plugins/tree-view/components/Treeview.tsx), `/plugins/tree-view` | [Collapsible](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/layout/collapsible.tsx) and Checkbox can build small disclosure lists, not a complete tree interaction model. | Large or editable/selectable trees requiring tree roles, roving focus, hierarchy navigation or virtualization. Legacy uses react-arborist; inspect its custom row behavior before relying on keyboard/drag support. |
| Geospatial map: [Leaflet examples](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/maps/leaflet/components/LeaFletMap.tsx), `/maps/leaflet` | [Popover](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/overlays/popover.tsx) can present details; no native map engine is catalogued. | Required spatial layers, markers, geometry or location interaction. Legacy supplies Leaflet examples; verify actual subcomponents, data/tile contracts, keyboard access and a non-map alternative against the selected use case. |
| Financial chart rendering: [candlestick implementation](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/charts/apex/candlestick/components/CandleStickChart.tsx), `/charts/apex/candlestick` | [Chart](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/data-display/chart.tsx) wraps Recharts; current panels do not demonstrate OHLC candles or synchronized candle/volume views. | A feature requiring those encodings/interactions. Legacy uses ApexChart; first investigate compatible Recharts composition before adding another engine. Confirm scale, tooltip meaning, data access and performance requirements. |
| Color and date-time editing: [ColorPicker](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/pickers/components/ColorPicker.tsx), [Pickers](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/reference/inspinia-showroom/src/views/admin/form/pickers/components/Pickers.tsx), `/form/pickers` | [Input](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/src/demos/forms/input.tsx), Slider, Popover and Date Picker provide parts; no equivalent color-space/timezone workflow is demonstrated. | Required alpha/color formats or date-time semantics beyond native browser inputs. Legacy uses react-colorful/Flatpickr, but some demo callbacks are incomplete. Define formats, timezones, validation and keyboard operation before choosing custom or specialist UI. |

## Styling and maintenance boundaries

Native examples use the canonical theme contract and expose source/classes for
layout changes. Preserve semantic tokens, visible focus, contrast and responsive
behavior when applying legacy visual ideas. Legacy utility classes and Preline
`data-hs-*` interactions belong to its independent runtime; copying markup into
native code does not preserve those interactions.

Read [native compatibility](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/apps/showroom/COMPATIBILITY.md) and the
[reference provenance](https://github.com/vossiman/dataprospectors-design-system/blob/d62f9df66a9388c197255ecff486a16b45346b73/docs/notes/active/2026-09-30-reference-import.md). shadcn source is
code we maintain, with a pinned mixed backend baseline: primarily Radix, Base UI
for Combobox, and `@shadcn/react` for Message Scroller. Compose against a compatible
consumer baseline; neither copied source nor a new dependency removes upgrade work.
Specialists add their own versions, styles, licensing and integration obligations.

## Unassessed patterns and next decision

Not assessed: the remaining individual UI variants, authentication/business pages,
permission models, commerce/invoice/email/file-manager workflows, advanced table
extensions (fixed columns, child rows, remote data and large datasets), most
Apex/ECharts encodings, Google/vector maps, tours, diff/PDF/video viewers, masonry,
idle timers, internationalization and other plugin pages. They remain reference
candidates needing feature requirements and representative implementation evidence.
No inference of coverage or a custom gap should be made from their names.

For the next selected feature, state its behavior, data/scale, keyboard needs and
consumer baseline; try the linked native starting point and inspect only the
relevant legacy extra. File implementation work only for a demonstrated missing
capability. This assessment preserves the full catalogue and does not block
modular skill publication (ticket 6).
