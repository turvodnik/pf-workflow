# Acceptance criteria: three kinds, and the check that sorts them

A criterion is a promise that a command or an observation will tell the truth
about the work. Three kinds keep that promise in three different ways, and
applying one kind's rule to another kind destroys the criterion. The author of
the packet sorts them BEFORE handing the work out — that is the cheapest moment,
and the only one where a rewrite costs nothing.

## 1. Change criterion — must be RED before the work

It proves that something NEW exists. Run its command against current HEAD before
handing the packet out; it must report «not satisfied». Green on the untouched
tree, it is not a criterion but the look of one: it passes whether or not the
work happens, and the reviewer cannot tell the two apart.

Green? Rewrite it to key on something that could not exist before the edit.

The case that produced this rule (T-073, 2026-09-04): the criterion read
`grep -c "ai-secret run" <шаблон>` ≥ 1, and the template already carried that
substring inside a placeholder — `<чего не трогать; секреты — только через
ai-secret run (§5); …>`. The criterion was green on an untouched file. The work
(making the line a constant outside the placeholder) was real, but the criterion
measured none of it. The honest replacement was a string that could not have
existed before: `grep -c "Широкие команды над секретами запрещены"` → 0 before,
1 after, both shown as `git show <sha>^:<file>` / `git show <sha>:<file>`.

## 2. Invariant criterion — must be GREEN throughout

It guards a boundary rather than proving a change: «nothing broke», «nothing
went outward», «nothing outside the scope was touched», «no regression». It is
green before the work and must still be green after. Demanding that it be red
first inverts it into a demand that the violation exist.

Two live examples from the same wave, both legitimate, both green from the
start:

- T-085, criterion 4 — `grep -c "/Users/" agents/pf-*.md` = 0. It guards §6:
  role files sync into a public distribution, so an absolute path from one
  machine must never appear in them. Rewriting it "so it is red first" would
  mean requiring that an absolute path be there.
- T-084, criterion 5 — `git tag --points-at HEAD` empty in the distribution
  clone. It guards «наружу ничего не опубликовано»: a public release needs an
  independent hostile QA pass first (§6). Red-first is meaningless here.

Two duties come with an invariant, and neither is optional:

1. **Mark it as an invariant in the packet**, so the executor and the reviewer
   know its green is expected, not accidental.
2. **Show that it goes red when the boundary is violated.** The violation is
   staged deliberately — on a copy of the file, on a throwaway clone, or by
   mutation — never waited for. A mutation carries an anchor that proves it
   landed (`assert old in s` before the substitution): an unanchored mutation
   silently misses, the check stays green, and the green is then read as «the
   guard works». That failure is the single most repeated one in our retros
   (×9). An invariant nobody has ever seen fail is
   indistinguishable from a check that cannot fail: a `grep` for a pattern with
   a typo in it is green forever, and green forever is exactly what a working
   guard also looks like (§11: «не смог проверить» ≠ «проверил»).

The staged control belongs in «Результат» next to the criterion, as command
output — «I copied the file, inserted `/Users/`, the grep reported 1».

## Compound criteria: split before sorting

A third of real criteria carry two things in one bullet — a proof of new
behaviour AND a guard. Live count in this wave: 4 of 13 (T-078 к1, к2, к5;
T-082 к2).

T-082 к2 is the clean example: «`json.load(settings.json)` without errors;
`hooks.PreToolUse` grows by exactly 1, **the Orca entry still in place**». The
first half is a change criterion — the hook is not installed yet. The second
half is an invariant, and not a small one: the spec's own risk list opens with
«ложная блокировка хуком ломает все сессии, включая автопилот», and that Orca
entry is what stands between the wave and a broken machine.

Sorting such a bullet by its dominant half is what destroys it. Whichever half
loses, loses BOTH duties of an invariant — the mark that tells the reviewer its
green is expected, and the staged failure that proves the guard can fail at all.
The guard is always the half that looks smaller, so it is always the half that
disappears.

So: split the bullet into two criteria, or mark each half with its own kind
inside the bullet. Never pick a dominant.

The counter-case matters as much: a bullet whose halves ALL fail on current HEAD
is ONE change criterion, not a compound. T-082 к4 («`printenv` → 2 with a
reason; the same with `printenv PATH` → 0») looks like a proof plus a guard, but
neither half can pass today — the hook does not exist, so both halves error out.
The second half is the negative control of the same new behaviour, and splitting
it off would turn a built-in control into a separate invariant that guards
nothing. Split only when one half would pass today and another would not — that
difference is what makes a bullet genuinely compound. Splitting is preferred — two lines
cost nothing, and each gets its own evidence in «Результат».

## 3. Observation criterion — must name the artifact and the way to look

Some things are checked by a person or by a subagent's behaviour, not by exit
code: a probe quoting a line it could only have read from the current edition,
a report whose last substantive section says X, a rendering that looks right.
Rule 6's own wording admits this — «verifiable by command **or** observation».

Such a criterion is neither red-first nor green-throughout. It is valid when it
names two things: WHICH artifact is inspected, and HOW a person decides. «The
skill works» is not a criterion. «A `general-purpose` subagent, given the file
as its only contract and ordered to `Read` it, quotes a line that this edit
added» is one — the artifact is the subagent's answer, and the decision rule is
whether the quoted line appears in the diff.

## Sorting in practice

Ask what the criterion would prove if it were green tomorrow with no work done:

- «nothing, it would just mean the work is invisible» → change criterion, and it
  must be red today;
- «that the boundary still holds» → invariant, and stage its failure once;
- «a person or a probe has to look, the verdict is a judgement» → observation,
  and name the artifact and the eye that checks it. Commands may be run inside
  it: «ревьюер сам запускает тесты и цитирует вывод» is an observation, because
  what settles it is a person reading the output, not an exit code. Probe run
  2026-09-04: this was the one branch a reader could not apply — «nothing a
  command settles» reads as «no commands involved», and the gate criterion that
  stands in every packet of the wave fell outside all three kinds.
