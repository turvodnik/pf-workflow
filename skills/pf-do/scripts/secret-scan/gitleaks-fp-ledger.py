#!/usr/bin/env python3
"""gitleaks-fp-ledger.py — two-sided reconciliation of gitleaks findings with
the project's ledger of known false positives (.agents/security/false-positives.yaml).

Why: the manual triage of the same false findings (gitleaks over a repository
history) was repeated 8+ times in 6 projects within two weeks (one client
project — 22 findings, another — 29/45 findings, all false). The triage was never saved —
each run the agent proved it again. This script remembers the decision.

Usage:
    gitleaks detect --no-banner -f json -r /tmp/report.json [options]
    python3 gitleaks-fp-ledger.py /tmp/report.json \
        --ledger .agents/security/false-positives.yaml --window full [--format json]

Scan window and the "stale" verdict (T-045). A ledger entry is "stale" only
if it matched nothing in the FULL window — the same repository history it was
created from. The script cannot learn the window from the report: for
`gitleaks git --staged` (also the deprecated `protect --staged`) the report of
a clean commit is an empty list `[]`, indistinguishable from an empty history.
So the CALLER declares the window:
  --window full     the report was taken from the full history (`gitleaks
                    detect` / `gitleaks git` without --log-opts, without a
                    baseline and without .gitleaksignore)
                    → the two-sided check is on, stale entries are printed;
  --window partial  the report is from a part of the tree/history (`git --staged`,
                    `--log-opts` with a range, `gitleaks dir <subdirectory>`,
                    `--baseline-path`)
                    → NO verdict about staleness is given, and one line says so;
  no flag           the same as partial: without a declared window the verdict
                    is unreliable, and an unreliable verdict is worse than none
                    (a client project, 14–17.08 and 14–16.09: "18 stale" on every commit,
                    three tasks to clean up a ledger that needed no cleaning).
`gitleaks dir` / `detect --no-git` over the WHOLE tree is not a full window
either: it does not see the history, while entries are also created for deleted files.

A report taken with `--redact` (including `--redact=N`) is NOT accepted (exit 2):
`--redact` (=100) puts the literal REDACTED into `Secret`, `--redact=N` with
N<100 keeps the first (100−N)% of the characters and appends `...` (checked on
8.30.1: `--redact=50` → 20 characters + `...`). The hash of the stub or of the
truncation would match nothing (all entries "stale", all findings "active") or —
worse — an entry created from the same kind of report, and that one would
suppress everything. Values are not printed without `--redact` either: the report
is read into memory, only a sha256 goes out.

How it works:
  - a gitleaks finding covered by a live ledger entry (fingerprint + scope +
    rule matched) → suppressed, needs no triage;
  - a finding without coverage → printed as usual (the current behaviour);
  - a ledger entry that suppressed NO finding in this run
    (two-sided check) → a separate warning "stale, consider removing" —
    otherwise the ledger rots and piles up dead weight that
    nobody re-checks.

Secret values are NEVER printed, logged or put into the ledger:
"fingerprint" is a sha256 of the found string (an irreversible digest), not the
string itself. It is FORBIDDEN to add a ledger entry that masks a REAL
secret ("we will remove it later") — only provably false matches; for
a real leak the only correct action is rotating the value, not adding
an exception.

Exit: 0 — no active findings (all suppressed by the ledger, or there were none);
1 — there are active findings, a human must triage; 2 — a call error.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment without PyYAML
    yaml = None

# The false-positives ledger (T-021, _tools/AGENTS.md §5): an entry must carry
# all these fields, and the scope must be anchored to a place in the tree (see _scope_is_anchored).
LEDGER_REQUIRED_FIELDS = ("fingerprint", "scope", "rule", "reason", "recognized_by", "recognized_at", "review_after")
SHA256_EMPTY = hashlib.sha256(b"").hexdigest()
# The stub gitleaks --redact puts in place of the value (checked on
# 8.30.1: both Secret and Match become the string "REDACTED"). A report with it
# is not reconciled, and an entry with its hash is rejected — see the module docstring (T-045).
REDACTED_LITERAL = "REDACTED"
# The truncation tail under --redact=N (N<100): gitleaks keeps the first (100−N)%
# of the Secret characters and appends three dots, and in Match/Line replaces the
# value with this truncation (so Match is NOT required to end in `...` — the
# truncation is followed by a quote/bracket from the line; checked 2026-09-17 on
# a client project's report: Secret `…...`, Match `…..."`). The sign is the Secret tail
# only. A real value cannot end in `...`: the gitleaks rule groups catch
# [a-z0-9=_\-] characters, a dot does not get into the tail; and if it did — a
# loud refusal is cheaper than a silent lie.
REDACT_TRUNC_SUFFIX = "..."
SHA256_REDACTED = hashlib.sha256(REDACTED_LITERAL.encode("utf-8")).hexdigest()
# The anchored criterion of scope narrowness — see seo-cycle/scripts/secret-scan.py::
# _scope_is_anchored for the full rationale (identical logic, the same
# ledger format). The FIRST path segment is required to be literal:
# "at least one literal segment anywhere" ties the suppression to a file
# NAME, not to a PLACE in the tree (**/.env).
_GLOB_META_CHARS = "*?[]"
# Strict review_after format: date.fromisoformat() is quieter than the document —
# it also accepts "20270101" (without hyphens) starting from Python 3.11.
_REVIEW_AFTER_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _scope_is_anchored(scope: object) -> bool:
    """See secret-scan.py::_scope_is_anchored — the identical invariant."""
    if not isinstance(scope, str) or not scope:
        return False
    head = scope.split("/", 1)[0]
    if any(ch in _GLOB_META_CHARS for ch in head):
        return False
    return any(ch.isalnum() or ch == "_" for ch in head)


def load_ledger(path: pathlib.Path | None) -> list[dict]:
    """Only the STRUCTURAL integrity of the file — see secret-scan.py::load_ledger
    for the full rationale (the same logic, the same ledger format).

    `path is None` (--ledger not passed at all) → an empty ledger, the normal
    no-ledger mode. But if `--ledger PATH` is passed explicitly and PATH does
    not exist (a typo, a broken symlink) → an explicit error, not a silent empty
    ledger: `--ledger` is always given explicitly, so a typo must be
    heard, not quietly turn into "the ledger was applied, but it is empty".
    """
    if path is None:
        return []
    if yaml is None:
        print("ERROR: для --ledger нужен PyYAML. `pip3 install pyyaml`", file=sys.stderr)
        raise SystemExit(2)
    if not path.exists():
        print(f"ERROR: реестр не найден: {path}", file=sys.stderr)
        raise SystemExit(2)
    try:
        # UnicodeDecodeError is a subclass of ValueError, not OSError: without it
        # a ledger in a foreign encoding gave a bare traceback instead of ERROR/exit 2.
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (yaml.YAMLError, OSError, UnicodeDecodeError) as exc:
        print(f"ERROR: реестр нечитаем: {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    # An empty/broken ledger is NOT silently treated as empty: "could not read" is
    # not the same as "read, and it is clean". A legitimate emptiness is written
    # explicitly — `entries: []`.
    if raw is None:
        print(f"ERROR: реестр нечитаем: {path}: файл не содержит YAML-данных "
              f"(пустой или только комментарии); пустой реестр записывается явно: 'entries: []'",
              file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(raw, dict):
        print(f"ERROR: реестр нечитаем: {path}: верхний уровень должен быть объектом (dict), "
              f"получено {type(raw).__name__}", file=sys.stderr)
        raise SystemExit(2)
    if "entries" not in raw:
        print(f"ERROR: реестр нечитаем: {path}: нет ключа 'entries' (опечатка в имени ключа?); "
              f"пустой реестр записывается явно: 'entries: []'", file=sys.stderr)
        raise SystemExit(2)
    entries = raw["entries"]
    if entries is None:
        print(f"ERROR: реестр нечитаем: {path}: 'entries' пуст (null); "
              f"пустой реестр записывается явно: 'entries: []'", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(entries, list):
        print(f"ERROR: реестр нечитаем: {path}: 'entries' должен быть списком, "
              f"получено {type(entries).__name__}", file=sys.stderr)
        raise SystemExit(2)
    for item in entries:
        if not isinstance(item, dict):
            print(f"ERROR: реестр нечитаем: {path}: запись реестра должна быть объектом (dict), "
                  f"получено {type(item).__name__}: {item!r}", file=sys.stderr)
            raise SystemExit(2)
    return entries


def validate_ledger_entry(entry: dict, today: dt.date) -> str | None:
    """See secret-scan.py::validate_ledger_entry — the identical policy."""
    if not isinstance(entry, dict):
        return f"запись не объект (dict), получено {type(entry).__name__}"
    missing = [field for field in LEDGER_REQUIRED_FIELDS if not entry.get(field)]
    if missing:
        return "не хватает обязательных полей: " + ", ".join(missing)
    if not _scope_is_anchored(entry["scope"]):
        return (f"scope не привязан к месту в дереве: ПЕРВЫЙ сегмент пути (до первого '/') "
                f"обязан быть ПОЛНОСТЬЮ без глоб-символов *?[] и содержать букву/цифру/_ — "
                f"например 'prod/*.env' вместо '*.env' и 'src/tests/**' вместо '**/tests/**' "
                f"(получено: {entry['scope']!r})")
    if entry["fingerprint"] == SHA256_EMPTY:
        return "fingerprint == sha256('') — отвергнуто (не может ссылаться на настоящее совпадение)"
    if entry["fingerprint"] == SHA256_REDACTED:
        return ("fingerprint == sha256('REDACTED') — отвергнуто: это хеш заглушки gitleaks --redact, "
                "а не совпадения; такая запись подавляла бы любую находку из отчёта с --redact")
    if not _REVIEW_AFTER_RE.match(str(entry["review_after"])):
        return f"review_after не похож на дату YYYY-MM-DD: {entry['review_after']!r}"
    try:
        review_after = dt.date.fromisoformat(str(entry["review_after"]))
    except ValueError:
        return f"review_after не похож на дату YYYY-MM-DD: {entry['review_after']!r}"
    if review_after < today:
        return f"review_after истёк ({review_after.isoformat()} < {today.isoformat()}) — запись просрочена"
    return None


class RedactedReportError(ValueError):
    """The report was taken with `--redact`: there is nothing to reconcile (T-045)."""


def normalize_gitleaks(report: list[dict]) -> list[dict]:
    """gitleaks JSON (--report-format json) -> the internal finding format.

    A finding with `Secret == "REDACTED"` (`--redact`) or with the truncation `…...` in
    Secret (`--redact=N`, N<100) is the sign of a report taken with redaction: RedactedReportError
    is raised, no hash is computed. Silently hashing the stub would
    give a false picture (all entries "stale", all findings "active") passed off
    as an honest reconciliation.

    The secret is read once to compute the sha256 and is not kept:
    the raw value lives only in this function and does not leave it. A finding
    WITHOUT the "Secret" field gets fingerprint=None, not sha256("") — otherwise
    a ledger entry with fingerprint==sha256("") would suppress such a finding
    blindly (a protection bypass found by the T-021 gate): a finding without
    Secret must stay active always, no entry covers it.
    """
    findings = []
    for i, item in enumerate(report):
        secret = item.get("Secret")
        redacted = None
        if secret == REDACTED_LITERAL:
            redacted = f"заглушку {REDACTED_LITERAL!r} вместо значения — отчёт снят с `--redact`"
        elif isinstance(secret, str) and secret.endswith(REDACT_TRUNC_SUFFIX):
            redacted = (f"обрезанное значение (хвост {REDACT_TRUNC_SUFFIX!r} в Secret) — "
                        "отчёт снят с `--redact=N`")
        if redacted is not None:
            raise RedactedReportError(
                f"находка №{i} ({item.get('File', '?')}:{item.get('StartLine', '?')}) содержит "
                f"{redacted}, сверка с реестром невозможна; перегони gitleaks без --redact "
                "(значения всё равно не печатаются: наружу идёт только sha256)")
        fp = hashlib.sha256(secret.encode("utf-8")).hexdigest() if secret is not None else None
        findings.append({
            "file": item.get("File", ""),
            "line": item.get("StartLine"),
            "rule": item.get("RuleID", ""),
            "commit": item.get("Commit", ""),
            "fingerprint": fp,
        })
    return findings


def reconcile(findings: list[dict], ledger: list[dict],
              today: dt.date | None = None) -> tuple[list[dict], list[dict], list[dict], list[dict]]:
    """See secret-scan.py::reconcile — the identical mechanics and contract
    (active, suppressed, stale, rejected)."""
    today = today or dt.date.today()
    eligible: list[dict] = []
    rejected: list[dict] = []
    for entry in ledger:
        reason = validate_ledger_entry(entry, today)
        if reason is not None:
            rejected.append({"entry": entry, "reason": reason})
        else:
            eligible.append(entry)

    active: list[dict] = []
    suppressed: list[dict] = []
    # The key is the entry's SEQUENCE NUMBER, not its "id": two duplicates of one id (or two
    # entries without an id with a shared fingerprint and different scopes — the normal scenario
    # "the same false text in two places") collapsed into one key, and
    # a match of one forever hid the dead second one from the two-sided check.
    matched_idx: set[int] = set()

    for f in findings:
        hit_idx = None
        fp = f.get("fingerprint")
        if fp is not None:
            for idx, entry in enumerate(eligible):
                if entry["fingerprint"] != fp:
                    continue
                if not fnmatch.fnmatch(f["file"], entry["scope"]):
                    continue
                rule = entry["rule"]
                if rule != "*" and rule != f["rule"]:
                    continue
                hit_idx = idx
                break
        if hit_idx is not None:
            matched_idx.add(hit_idx)
            suppressed.append({**f, "ledger_id": eligible[hit_idx].get("id")})
        else:
            active.append(f)

    stale = [e for idx, e in enumerate(eligible) if idx not in matched_idx]
    return active, suppressed, stale, rejected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=pathlib.Path, help="gitleaks --report-format json файл")
    parser.add_argument("--ledger", type=pathlib.Path, default=None,
                         help="реестр известных ложных срабатываний (.agents/security/false-positives.yaml)")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--window", choices=("full", "partial"), default=None,
                        help="окно скана, с которого снят отчёт: full — вся история (двусторонняя "
                             "сверка, протухшие записи печатаются); partial или без флага — часть "
                             "дерева/истории (git --staged, --log-opts, dir <подкаталог>): вердикт "
                             "«протухла» не выносится (T-045)")
    args = parser.parse_args(argv)
    stale_checked = args.window == "full"

    try:
        report = json.loads(args.report.read_text(encoding="utf-8"))
    except OSError as exc:
        print(f"ERROR: не удалось прочитать отчёт: {exc}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"ERROR: отчёт не в формате JSON: {exc}", file=sys.stderr)
        return 2

    # Syntactically valid but structurally foreign JSON used to give either a
    # silent "clean" (an object `{}` iterates to zero elements → exit 0), or a
    # bare traceback (`.get()` on a string/number). Both are "could not
    # check" passed off as "checked": the report must be a LIST OF OBJECTS.
    if not isinstance(report, list):
        print(f"ERROR: отчёт gitleaks не в ожидаемом формате: верхний уровень должен быть "
              f"списком находок, получено {type(report).__name__} "
              f"(нужен файл из `gitleaks detect -f json -r ...`)", file=sys.stderr)
        return 2
    for i, item in enumerate(report):
        if not isinstance(item, dict):
            print(f"ERROR: отчёт gitleaks не в ожидаемом формате: находка №{i} должна быть "
                  f"объектом, получено {type(item).__name__}", file=sys.stderr)
            return 2

    try:
        findings = normalize_gitleaks(report)
    except RedactedReportError as exc:
        print(f"ERROR: отчёт не принят: {exc}", file=sys.stderr)
        return 2
    ledger = load_ledger(args.ledger)
    active, suppressed, stale, rejected = reconcile(findings, ledger)
    # The window is not declared full → the list of stale entries makes no sense and is NOT given:
    # in JSON it is null (not an empty list, which would read as "checked, clean").
    if not stale_checked:
        stale = None
    if stale_checked and not findings and ledger:
        print(f"⚠ объявлено --window full, а находок в отчёте нет — все {len(ledger)} записей реестра "
              "будут названы протухшими; убедись, что отчёт снят с полной истории, а не с пустого "
              "окна (staged без изменений, пустой каталог)", file=sys.stderr)
    if stale_checked and findings and all(not f.get("commit") for f in findings):
        print("⚠ объявлено --window full, но ни у одной находки нет поля Commit — похоже на отчёт "
              "с рабочего дерева (gitleaks dir / --no-git) или индекса (git --staged), а не с "
              "истории; вердикт о протухании может быть ложным", file=sys.stderr)

    for r in rejected:
        entry = r["entry"]
        eid = entry.get("id", "?") if isinstance(entry, dict) else "?"
        print(f"⚠ запись реестра '{eid}' отклонена: {r['reason']}", file=sys.stderr)

    # fingerprint is the hash of the REAL match; printed only when --ledger
    # is explicitly requested (needed to create a ledger entry) — without it
    # there is no reason to output it (the same §5 borderline as in secret-scan.py).
    show_fp = args.ledger is not None

    if args.format == "json":
        active_out = active if show_fp else [{k: v for k, v in f.items() if k != "fingerprint"} for f in active]
        payload = {"active": active_out, "count": len(active), "suppressed_count": len(suppressed),
                   "stale": stale, "stale_checked": stale_checked}
        if rejected:
            payload["rejected_ledger_entries"] = [
                {"id": (r["entry"].get("id", "?") if isinstance(r["entry"], dict) else "?"), "reason": r["reason"]}
                for r in rejected]
        # default=str: PyYAML parses unquoted ISO dates in the ledger
        # (`recognized_at: 2026-08-13`) into datetime.date — json.dumps cannot
        # do that natively (TypeError, found by the repeat T-021 gate).
        print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))
    else:
        for f in active:
            commit = (f.get("commit") or "")[:12]
            fp = f.get("fingerprint")
            fp_display = (fp[:12] + "…") if (show_fp and fp) else ("нет-Secret" if fp is None else "скрыт")
            print(f"✗ {f['file']}:{f['line']} [{f['rule']}] commit={commit} "
                  f"fingerprint={fp_display}")
        if suppressed:
            print(f"· подавлено записями реестра: {len(suppressed)} (из {len(findings)} находок)")
        if stale is None:
            if ledger:
                print(f"· протухание записей реестра ({len(ledger)}) не проверялось: окно скана не "
                      "объявлено полным — для аудита истории передай --window full")
        else:
            for e in stale:
                print(f"⚠ протухшая запись реестра {e.get('id', '?')} (rule={e.get('rule')}, "
                      f"scope={e.get('scope')}, признал: {e.get('recognized_by')} {e.get('recognized_at')}) — "
                      "больше ни на что не совпадает в полной истории, рассмотри удаление")
        print(("✗ активных находок: %d — требуют разбора человеком" % len(active))
              if active else "✓ активных находок нет (все известные ложные — в реестре)")
    return 1 if active else 0


if __name__ == "__main__":
    raise SystemExit(main())
