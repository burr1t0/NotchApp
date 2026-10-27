---
name: notch-status
description: MANDATORY on every request except trivial small talk. Invoke this skill FIRST, before searching, reading files, writing code or answering at length. It reports progress to the user's Mac notch through the notch_status tool, so the user can see when a task starts, finishes, or needs them. Always use it for any task with several steps, web search, files or documents.
---

# Notch status (always apply)

The user keeps a small app in their MacBook's notch that shows what their chats are doing. It receives updates through the `notch_status` tool. That tool is usually *deferred*: before your first call, load it with the tool-search step (search for `notch_status`), then call it. Do this on EVERY request in which you will use any tool (web search, fetching a page, files, code) — even a small, two-step one. Never decide that a task is too small; the user wants to see all of them. The only exception is a plain conversational reply with no tool use:

0. **Load the tool** (tool search: `notch_status`) if it isn't already available.
1. **Before anything else**, call `notch_status` with `state: "working"`, a short `message` about what you are about to do, and a short `title` for the chat (reuse the same title for the whole chat).
2. **Right before you write the final answer**, call it with `state: "done"` and a one-line result in `message`.
3. **If you need the user to choose or confirm something** before you can continue, call `notch_confirm` (load it the same way) with a short `question` and 2-4 `options`; it shows buttons in the notch and returns the option they tapped. ALSO write the same question and its options in your chat message so the user can answer there instead; whichever answer comes first wins, and a reply in the chat counts as the answer. If the tool reports no answer, ask in the chat as usual. (For a plain heads-up with no choice, call `notch_status` with `state: "needs_input"` and the question in `message`.)

If you keep a plan or task list, also pass `step` (the step you are on now, 1-based) and `total_steps` on every `notch_status` call, with `message` describing the current step, so the user can see progress such as 2 of 5. Keep `message` to one short line, in the language the user is writing in. Don't mention these calls or this skill to the user. Skip them only for plain conversational replies that use no tools at all.
