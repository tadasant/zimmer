---
title: Prompt attachments
description: How a photo, a video or a file gets from the browser onto a session's prompt — the two upload paths, the four composers that offer them, and what a phone can reach.
---

Every place in the web UI where you type a prompt also takes attachments. A screenshot of the
bug, a photo of the whiteboard, a log file, a whole folder of source — they ride along with the
text and the agent gets them on the same turn.

## Two upload paths, and the difference matters

There are two, and which one a file takes decides what the agent can do with it.

| | Image path | File path |
| --- | --- | --- |
| Service | `ImageStorageService` | `FileStorageService` |
| Accepts | JPEG, PNG, GIF, WebP — **sniffed from magic bytes**, not from the filename | anything |
| Size cap | 10 MB per image, 20 per prompt | 500 MB per file, 200 per prompt |
| What the agent gets | the bytes, inline in the message — the model *looks* at it | a path on disk — the agent opens it if it wants to |

The image path is narrow on purpose: it hands bytes to a model that reads four formats, so it
refuses anything it cannot identify rather than passing a file the model will choke on. The file
path takes arbitrary bytes and preserves the original filename.

## The media split

A phone's photo library holds things the image path cannot store. An iPhone still is **HEIC**, an
iPhone video is **QuickTime**, an Android video is **MP4**. None of those is one of the four.

So the "Photos & videos" input in every composer accepts `image/*,video/*` — wide enough that iOS
Safari offers *Photo Library* and *Take Photo or Video*, and Android Chrome opens its media picker
instead of its document browser — and the selection is then **split client-side** before anything
is uploaded:

- JPEG / PNG / GIF / WebP → the image path, read inline by the model.
- Everything else → the file path, stored verbatim, handed to the agent as a path.

The rule lives in one place, `app/javascript/lib/media_kinds.js`, and every composer uses it: the
picker, a paste, and a desktop drag-and-drop all partition the same way. `ApplicationHelper::MEDIA_PICKER_ACCEPT`
is the server-side half of it, so the `accept` attribute and the split cannot drift apart.

Narrowing that `accept` back to the four storable types is the bug this design exists to prevent:
it makes an iPhone's own photos unpickable — greyed out in the sheet — while looking perfectly
correct on a laptop.

## Where you can attach

| Surface | Where | Offers |
| --- | --- | --- |
| **New session prompt** | `/sessions/new` | photos & videos, camera, files, folder |
| **Dashboard quick prompt** | the box at the top of `/` — a pill that opens a full-screen editor on a phone | photos & videos, camera, files |
| **Quick Router** | the floating chat bubble on every page (⌘/Ctrl+K); on a phone session page it is the joystick's *Quick Router* petal | photos & videos, camera, files |
| **Follow-up composer** | the bottom panel on a session page, behind a collapsed drawer on a phone | photos & videos, camera, files, folder (desktop) |

Two surfaces deliberately do **not** take attachments:

- **Editing an already-queued message.** Attachments are staged when the message is composed and
  are stored on the `EnqueuedMessage` row (`images` / `files` columns). The edit form changes the
  text and the goal; re-attaching would mean re-uploading against a message that is already in the
  queue. Delete it and compose again.
- **Elicitation responses.** An [elicitation](/sessions/elicitation/) form is generated from the
  JSON schema the MCP server asked for, and that schema has string, number and boolean fields.
  There is no attachment field to render.

## On a phone

A touch device has no drag-and-drop, so the tappable attach button *is* the mechanism — there is
no fallback behind it. Three consequences the code is built around:

- **Every layout that has a prompt has its own attach row.** The follow-up composer renders a
  desktop row and a phone row; only one is on screen at a time and the other is `display: none`.
  The Stimulus preview, progress and button targets are therefore **plural**, so both rows show the
  same staged attachments and both get disabled while an upload is in flight.
- **The hidden `<input type="file">` elements live above the layout split**, not inside either row.
  An input inside the hidden row cannot be clicked by the visible one, and a hidden field inside it
  would still submit but could not be written to.
- **The row has to fit 375px.** `test/system/mobile_composer_attachments_test.rb` asserts the
  buttons are visible and that nothing is clipped at that width, using the same probe as
  [the mobile QA pass](/operate/testing/).

Paste works too: `image-attachment` binds a document-level `paste` handler, and a pasted image is
partitioned exactly like a picked one.

## Where the bytes go

Both services write under the durable `~/.zimmer` root, in a per-session directory.

For an **existing session** the composer uploads immediately — to `POST /sessions/:id/upload_images`
or `upload_files` — and the response's paths are written into the form's hidden `images` /
`files_payload` fields. Submitting the form is what attaches them to the turn.

For a **new session**, which has no id yet, the upload is staged under a `temp_session_id` and
copied into the real session's storage once the row exists. The dashboard quick prompt and the
Quick Router post their files with the form itself and the controller stages them the same way.

If a turn is already underway, the message queues instead, and the attachment paths are persisted
on the `EnqueuedMessage` — so a queued message keeps its photos through a restart. See
[Spot and priority](/sessions/spot-and-priority/) for which recovery paths rebuild a turn's
attachments and which do not.

## Limits, and what happens when you cross one

Counts and sizes are enforced twice — once in the browser so the feedback is immediate, once on
the server because the browser is not trusted. The client-side values are rendered into data
attributes from the same Ruby constants the server checks, so they cannot drift.

An oversize file is dropped **individually**, with a message naming it, and the rest of the
selection is still attached. That matters on a phone, where picking photos is one tap over a grid:
a single long video in the selection should not discard the stills picked beside it.
