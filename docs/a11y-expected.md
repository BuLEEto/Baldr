# What a screen reader should say

What each widget is *meant* to report, so that a transcript of a real reader
can be judged rather than guessed at. Where a reader such as Orca says
something else, the difference is either Baldr's mapping — a bug worth
reporting — or the reader's own heuristics, which is worth knowing either
way.

This is what the toolkit puts on the accessibility bus. A reader chooses its
own words — "button Save", "Save button", "Save, button" are all the same
thing — so read the columns as *content*, not phrasing.

## Controls

| Widget | Role | Name | States it changes | Value |
|---|---|---|---|---|
| `button` | push button | its label | pressed while held; dimmed when disabled | — |
| `button(pressed =)` | toggle button | its label | pressed / not pressed | — |
| `checkbox` | check box | its label | checked / unchecked / partially checked | — |
| `radio` | radio button | its label | checked; within a radio group | — |
| `toggle` | toggle button | its label | checked / unchecked (a switch has no AT-SPI role of its own) | — |
| `slider` | slider | its label | focused | current, minimum, maximum, and the step its arrow keys use |
| `number` | spin button | its label | focused | as above |
| `progress` | progress bar | its label | busy while indeterminate | current, minimum, maximum |
| `link` | link | its text | — | — |
| `chip`, `badge` | static / label | its text | selected where it can be | — |

A control that is disabled reports neither enabled nor sensitive, and a
reader should say so rather than reading it as ordinary.

## Text

| Widget | Role | Name | Also |
|---|---|---|---|
| `text_input` | entry | its label, else its placeholder | single-line; its text, caret and selection; editable unless read-only |
| `text_input(password =)` | password text | its label | its text is bullets, which is what a reader should say |
| `text_area`, code, rich, markdown editors | text | its label | multi-line; text by character, word, line, sentence; caret and selection; editable unless read-only |
| `text` | static | its text | — |
| `text(role = .Title)` etc. | heading | its text | — |

For an editor a reader should be able to: read the whole thing, read by
line and by word, follow the caret as it moves, hear text inserted and
deleted as it is typed, and type into it — including cut, copy and paste.

## Containers and views

| Widget | Role | Name | Children |
|---|---|---|---|
| `list` | list | its label | list items, the chosen one selected |
| `table` | table | its label | rows and cells; a header cell reads as a column header |
| `tree_view` | tree | its label | tree items, expanded or collapsed |
| `icon_view` | list | its label | list items |
| `tabs` | page tab list | its label | page tabs, the current one selected |
| `menu_bar`, `menu` | menu bar, menu | its label | menu items, checked where they are |
| `dialog` | dialog | its title | modal; focus should land inside it |
| `toast` | notification | its text | — |
| `card`, `column`, `row` | panel / filler | usually none | whatever is inside |

## Charts and graphs

| Widget | Role | Name | Says |
|---|---|---|---|
| `chart` | grouping | its label | "Line chart, 3 series, values 0 to 90", and the point the keyboard is on; each series is a list item — "Sales, 12 points, 31.2 to 79.4, ending 61.5" |
| `graph` | grouping | its label | "4 nodes, 2 connections", and the node the keyboard is on; each node is a list item — "Amplifier, 1 in, 1 out, from Microphone, to Speakers" |

## Windows

A window reads as a frame with the app's title, and is active when it has
the keyboard. A window drawing its own title bar has that bar as a tool bar,
with buttons named Minimise, Maximise (or Restore) and Close.

## Events a reader should hear

- focus moving, on every control it lands on
- the caret moving in an editor, and text inserted or deleted as it is typed
- a value changing — a slider being dragged, a progress bar filling — **including when the app changes it rather than the user**
- a name or description changing under the reader
- a control's own state changing: checked, pressed, selected, expanded, enabled
- children arriving in or leaving a list

## Where silence is a bug

Silence is the failure this toolkit cannot detect from the inside, so it is
worth listing what should never be silent:

- a control taking focus
- a checkbox or toggle flipping, however it was flipped
- a slider moving, by drag, by key, or by the app
- a progress bar reaching its end
- a dialog opening (focus should move into it) and closing (focus should come back)
- a row becoming selected in a list or table
- text appearing in an editor as it is typed

## Known limits

- Deselecting, clearing a selection and select-all are refused: nothing in
  the toolkit knows what an app means by them.
- `GetAccessibleAtPoint` answers nothing — a reader asking "what is under
  this point" is not served yet.
- Per-character text attributes (a run's bold, its colour) are not reported;
  the whole text reads as one run.
- A chart's or a graph's marks are summarised, not traversable point by
  point through the tree; the keyboard walks them and the description
  follows, which is a different thing.
