---
name: cc-remind
description: The user's reminder inbox shared by every Claude Code session on this machine (also shown in the cc-remind desktop widget). ADD a reminder whenever the user must do something themselves (a decision, a payment, an account or identity step, a manual or physical check), when a result must be checked after this session ends ("check this tomorrow", "look at the numbers on Thursday"), or when another project's session must be told something ("tell the api-server project that..."). Also on "remind me", "note this for later", "don't let me forget". CLOSE a reminder as soon as you finish work that matches an open one, or when the user says it is done.
---

# cc-remind

A reminder inbox that every Claude Code session shares.
- Each item records the chat and project it came from automatically. You never type your own session id.
- At session start, a hook shows the open items addressed to this project, and the user's to-dos raised from it, most urgent first, with their ids. If it says "...and N more", run `cc-remind list` before working through reminders.

## Add
```
cc-remind add "<one concrete task>" [--to me|<project>] [--due "YYYY-MM-DD HH:mm"|+2h|+3d|tomorrow9] [--pr hi|mid|lo] [--note "<context needed to act>"]
```
- **One item = one task.** Never bundle. Big work becomes several items.
- **A note to another project must say what to do and when it counts as done.** Open with the action, then the close condition (e.g. `not needed = close it; needed = add an item back --to <sender>`). An FYI-only note leaves the reader unsure who should act.
- `--to`:
  - Default is `me`: the user does it.
  - A follow-up for this project's own future sessions (a result to check later) needs `--to <this project>`. Without it, the item lands on the user.
  - Use a project name (e.g. `api-server`, `my-app`) or a folder path when that project's Claude session must act. It will see the item when a session next starts there (or in a subfolder).
  - An unknown name fails with the list of known projects. Pick one from it; don't guess.
  - If two projects share the same folder name, pass the full path and check the `to:` line with `cc-remind show <id>`.
  - A folder where Claude Code has never run yet can be given as a full path. The widget's project list is built from past sessions, so it will not show that project yet; the item still appears in the inbox with a button to start a chat there. Tell the user where to find it.
- `--due`:
  - Only when there is a real time to act. The widget raises a Windows notification at that time.
  - Times are read and shown in the configured time zone (`cc-remind paths` shows it; default = this machine's).
- `--pr`: `hi` = blocks customers or money, or is urgent · `mid` is the default · `lo` = someday.
- `--note`: what the reader needs to act without opening this chat (URLs, names, commands). Never include secret values.
- After adding, tell the user in one line, e.g. `Noted [3f2a] check the import results (Thu 20:50)`.
- From PowerShell, `cc-remind` runs through `cc-remind.cmd`, and a straight double quote (`"`) inside the title or `--note` splits the argument: the rest spills into another field or is cut off. Leave inner quotes out (or use `'`), then check the result with `cc-remind show <id>`.
- If a write fails with `EPERM` on a `todos.json.*.tmp` rename, another process held the file for a moment. Check with `cc-remind list` before retrying, so the item is not added twice.

Add without being asked when:
1. The user must do something you cannot do.
2. A result has to be checked after this session ends.
3. A decision is pending.
4. Another project needs to know something.

Don't add:
- work you are about to finish in this session
- facts that belong in memory or CLAUDE.md

## Close
```
cc-remind done <id> "<what was done, one line>"
cc-remind done <id> --dropped "<why it is no longer needed>"
cc-remind list            # open items for this project (add --notes to see notes)
cc-remind list --all
cc-remind show <id> [<id>...]   # full note, ref, source
cc-remind snooze <id> "YYYY-MM-DD HH:mm"
cc-remind edit <id> [--title ...] [--due ...|none] [--pr ...] [--note ...] [--to ...]
cc-remind reopen <id>
```
- **Closing is part of finishing the work.** The widget tells the user which chat closed what.
- The common failure this system exists to fix is doing the work and never closing the item.
- Before you say a task is done, check `cc-remind list` for a matching item and close it.
- If the user says "X is done", close the matching item. You can close items from any project.
- `edit --note` replaces the whole note. To add context, copy the current note from `cc-remind show <id>` and pass old and new text together.
- Items flagged "still relevant?" (open more than 14 days): if you can verify one is obsolete, close it with `--dropped` and say why.

## Notes
- Data lives in the cc-remind data folder (`cc-remind paths`). Don't edit `todos.json` by hand; the CLI locks it.
- In auto mode the permission classifier reads the whole command line, reminder text included. A title or note that contains a risky runnable command (e.g. a merge or deploy command) can get the call blocked, and every `done` chained into the same call fails with it. Describe such actions in words, and run `add` separately from `done`.
