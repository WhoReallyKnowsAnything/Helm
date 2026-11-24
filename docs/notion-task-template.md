# Notion task template (Helm Tasks database)

Layout is defined in `orchestration/prompts/task-drafting-mode.md`, section "Task Row Layout".
`cad-notion-push` writes new rows in the same layout.

## Make the template in the Notion UI

The Notion API can list a data source's templates (`API-list-data-source-templates`).
No create-template endpoint is known to us (unverified against live docs), so make it by hand.

1. Open the Tasks database in Notion.
2. Click the arrow beside **New**, then **+ New template**.
3. Name it `Helm task`.
4. Set the icon to 🎯. (Sub-tasks: change to 🌊 when `Parent-task` is set.)
5. Paste this body:

```
## Description

## Acceptance criteria
-

## Files / area
-

## Depends on
None

## Notes
```

6. Close the template. Optionally set it as the default for the database.

Existing rows stay as they are. The orchestrator reads old free-text rows by its prose fallback.
