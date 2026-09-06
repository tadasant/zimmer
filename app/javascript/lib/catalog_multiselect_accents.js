// Accent colour classes for the catalog multi-select widget.
//
// EVERY class name here is written out in full, deliberately. Tailwind's content
// scanner reads this file as text (`@source "../../javascript/**/*.js"` in
// app/assets/tailwind/application.css) and keeps only the class names it can
// literally see. A tidier `bg-${accent}-100` would compile to nothing: the widget
// would look right in dev, where the JIT has already seen the token from some
// other file, and render unstyled in production. So: a lookup table of complete
// strings, never interpolation.
//
// Adding an accent means adding a whole row, not a colour name.
export const ACCENTS = {
  green: {
    chip: "bg-green-100 text-green-800",
    chipRemove: "text-green-600 hover:text-green-800",
    row: "hover:bg-green-50",
    categoryHeader: "text-green-700 bg-green-50 border-green-100"
  },
  indigo: {
    chip: "bg-indigo-100 text-indigo-800",
    chipRemove: "text-indigo-600 hover:text-indigo-800",
    row: "hover:bg-indigo-50",
    categoryHeader: "text-indigo-700 bg-indigo-50 border-indigo-100"
  },
  purple: {
    chip: "bg-purple-100 text-purple-800",
    chipRemove: "text-purple-600 hover:text-purple-800",
    row: "hover:bg-purple-50",
    categoryHeader: "text-purple-700 bg-purple-50 border-purple-100"
  },
  amber: {
    chip: "bg-amber-100 text-amber-800",
    chipRemove: "text-amber-600 hover:text-amber-800",
    row: "hover:bg-amber-50",
    categoryHeader: "text-amber-700 bg-amber-50 border-amber-100"
  }
}

// The tone an item carries when the catalog declares it unavailable. Two keys,
// not four: the flag only ever reaches a CHIP, so `row` and `categoryHeader`
// would be unreachable. Not interchangeable with an ACCENTS row — read only
// `chip` and `chipRemove` off it.
//
// One row rather than one per accent: the flag means the same thing whatever the
// artifact type, and amber is the colour the rest of Zimmer already uses for it
// (see lib/mcp_server_availability.js).
export const UNAVAILABLE = {
  chip: "bg-amber-100 text-amber-900",
  chipRemove: "text-amber-700 hover:text-amber-900"
}

// Fall back to green rather than throwing: an unknown accent should render a
// usable widget, not a blank one.
export function accentClasses(name) {
  return ACCENTS[name] || ACCENTS.green
}
