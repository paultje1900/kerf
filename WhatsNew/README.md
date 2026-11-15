# What's new

One file per change people notice. Kerf shows the ones you haven't seen after an update, and
offers an update as soon as `main` has notes your build doesn't.

Name it `<yyyy-mm-dd>-<a-few-words>.json` (lowercase, digits and dashes), dated the day you
write it:

```json
{
  "title": { "en": "Your merged pull requests", "nl": "Je gemergede pull requests" },
  "text": { "en": "One or two short sentences: what you can do now.", "nl": "Hetzelfde in het Nederlands." },
  "symbol": "arrow.triangle.merge",
  "by": "your-github-login"
}
```

- `title` and `text` in English and Dutch. Say what changes for the person using Kerf, not
  how it's built. Name the switch when it needs one (Settings → Features).
- `symbol`: an SF Symbol that fits; `sparkles` when nothing does.
- `by`: your GitHub login.
- A change nobody notices (a refactor, tests, docs) gets no note.
