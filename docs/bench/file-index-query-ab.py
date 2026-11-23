#!/usr/bin/env python3
"""MiscKit file-index query benchmark.

Replicates FileIndexDatabase.query() SQL shape against a snapshot of the real
index, and compares candidate predicate rewrites under one fingerprint.

Arms:
  baseline : LIKE prefix + LIKE contains (current source)
  glob     : prefix group uses GLOB (index range) instead of LIKE
  instr    : contains predicates use instr(name_folded, ?) > 0 instead of LIKE '%?%'
  combined : glob + instr
  mutant   : combined but with the query term NOT folded (deliberate semantic break)
"""
import json
import os
import random
import sqlite3
import statistics
import sys
import time
import unicodedata

DB = os.path.expanduser(os.environ.get("BENCH_DB", "~/.cache/misckit-bench/snapshot.sqlite3"))
LIMIT = 80
COUNT_CAP = 1000
REPS = 9

def fold(text):
    # Approximates FileIndexText.fold (NFC + case/diacritic/width insensitive + lowercased).
    # Corpus avoids full-width characters; ASCII + CJK behave identically here.
    return unicodedata.normalize("NFC", text).casefold()

def escape_like(text):
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

def escape_glob(text):
    out = []
    for ch in text:
        if ch in "*?[]":
            out.append("[" + ch + "]")
        else:
            out.append(ch)
    return "".join(out)

COLUMNS = "path, name, name_folded, is_directory, ext, kind, size, modified, created, last_used"

class Query:
    def __init__(self, label, terms, sort="relevance", category="all", scope="mac",
                 directories=(), folder_only=False, file_only=False, extensions=()):
        self.label = label
        self.terms = [dict(text=t, negated=n, wildcard=w) for (t, n, w) in terms]
        self.sort = sort
        self.category = category
        self.scope = scope
        self.directories = list(directories)
        self.folder_only = folder_only
        self.file_only = file_only
        self.extensions = list(extensions)

def base_filter(q):
    clauses, values = [], []
    if q.folder_only:
        clauses.append("is_directory = 1")
    if q.file_only:
        clauses.append("is_directory = 0")
    if q.extensions:
        clauses.append("ext IN (" + ",".join("?" * len(q.extensions)) + ")")
        values += q.extensions
    if q.category == "folder":
        clauses.append("is_directory = 1")
    elif q.category != "all":
        clauses.append("kind = ?")
        values.append(q.category)
    if q.scope == "folders":
        scopes = []
        for d in (q.directories or [os.path.expanduser("~")]):
            clean = d.rstrip("/") or "/"
            scopes.append("(path = ? OR (path >= ? AND path < ?))")
            values += [clean, clean + "/", clean + "0"]
        clauses.append("(" + " OR ".join(scopes) + ")")
    return clauses, values

def term_filter(q, arm, skipping=None):
    clauses, values = [], []
    for i, term in enumerate(q.terms):
        if i == skipping:
            continue
        folded = fold(term["text"])
        has_wc = term["wildcard"]
        if has_wc:
            # wildcard conversion: * -> %, ? -> _  (same as FileSearchSyntax.likePattern)
            pat = "%" + "".join("%" if c == "*" else "_" if c == "?" else escape_like(c)
                                for c in folded) + "%"
        else:
            pat = "%" + escape_like(folded) + "%"
        neg = "NOT " if term["negated"] else ""
        if arm in ("instr", "candidate", "mutant") and not has_wc:
            needle = folded if arm != "mutant" else term["text"]
            clauses.append(neg + "instr(name_folded, ?) > 0")
            values.append(needle)
        else:
            clauses.append("name_folded " + neg + "LIKE ? ESCAPE '\\'")
            values.append(pat)
    return clauses, values

def group_clause(group, folded, arm):
    if group == 0:
        return ["name_folded = ?"], [folded]
    esc = escape_like(folded) + "%"
    esc_contains = "%" + escape_like(folded) + "%"
    if group == 1 and arm in ("glob", "candidate", "mutant"):
        return ["name_folded GLOB ?"], [escape_glob(folded) + "*"]
    if group == 2 and arm in ("instr", "candidate", "mutant"):
        needle = folded if arm != "mutant" else folded  # contains needle is folded in both
        return ["instr(name_folded, ?) > 0"], [needle]
    if group == 1:
        return ["name_folded LIKE ? ESCAPE '\\'"], [esc]
    return ["name_folded LIKE ? ESCAPE '\\'"], [esc_contains]

def select(conn, clauses, values, order, limit):
    sql = "SELECT " + COLUMNS + " FROM entries WHERE " + \
          (" AND ".join(clauses) if clauses else "1=1") + " ORDER BY " + order + " LIMIT ?"
    cur = conn.execute(sql, values + [limit])
    return cur.fetchall()

def capped_count(conn, clauses, values):
    sql = ("SELECT COUNT(*) FROM (SELECT 1 FROM entries WHERE " +
           (" AND ".join(clauses) if clauses else "1=1") + " LIMIT ?)")
    cur = conn.execute(sql, values + [COUNT_CAP + 1])
    value = cur.fetchone()[0]
    return (COUNT_CAP, False) if value > COUNT_CAP else (value, True)

def run_query(conn, q, arm):
    base_clauses, base_values = base_filter(q)
    ranking = next((i for i, t in enumerate(q.terms) if not t["negated"]), None)
    name_order = "name_folded ASC, rowid ASC" if arm != "current" else "name_folded ASC"
    if q.sort == "relevance" and ranking is not None and q.terms[ranking]["text"] \
            and not q.terms[ranking]["wildcard"]:
        rest_clauses, rest_values = term_filter(q, arm, skipping=ranking)
        folded = fold(q.terms[ranking]["text"])
        if arm == "mutant":
            folded = q.terms[ranking]["text"]  # deliberate: skip fold
        collected, seen, exhausted = [], set(), True
        for group in range(3):
            if len(collected) > LIMIT:
                break
            gclauses, gvalues = group_clause(group, folded, arm)
            rows = select(conn, base_clauses + rest_clauses + gclauses,
                          base_values + rest_values + gvalues, name_order, LIMIT + 1)
            if len(rows) > LIMIT:
                exhausted = False
            for row in rows:
                if row[0] not in seen:
                    seen.add(row[0])
                    collected.append(row)
        items = collected[:LIMIT]
        if exhausted:
            total, exact = len(items), True
        else:
            total, exact = capped_count(conn, base_clauses + term_filter(q, arm)[0],
                                        base_values + term_filter(q, arm)[1])
        return items, total, exact

    suffix = "" if arm == "current" else ", rowid ASC"
    if q.sort == "relevance" or q.sort == "name":
        order = "name_folded ASC" + suffix
    elif q.sort == "modified":
        order = "COALESCE(modified, 0) DESC, name_folded ASC" + suffix
    elif q.sort == "created":
        order = "COALESCE(created, 0) DESC, name_folded ASC" + suffix
    elif q.sort == "size":
        order = "COALESCE(size, 0) DESC, name_folded ASC" + suffix
    else:
        order = "name_folded ASC" + suffix
    clauses, values = base_filter(q)
    tclauses, tvalues = term_filter(q, arm)
    rows = select(conn, clauses + tclauses, values + tvalues, order, LIMIT + 1)
    exhausted = len(rows) <= LIMIT
    items = rows[:LIMIT]
    if exhausted:
        return items, len(items), True
    full_clauses = clauses + term_filter(q, arm)[0]
    full_values = values + term_filter(q, arm)[1]
    total, exact = capped_count(conn, full_clauses, full_values)
    return items, total, exact

def signature(result):
    items, total, exact = result
    return (tuple(items), total, exact)

def connect(path, readonly=True):
    if readonly:
        conn = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=5)
    else:
        conn = sqlite3.connect(path)
    conn.execute("PRAGMA query_only=1")
    conn.execute("PRAGMA mmap_size=%d" % (1 << 28))
    conn.execute("PRAGMA cache_size=-32768")
    conn.execute("PRAGMA temp_store=MEMORY")
    return conn

def main():
    home = os.path.expanduser("~")
    corpus = [
        Query("single_common_report", [("report", False, False)]),
        Query("single_screenshot", [("screenshot", False, False)]),
        Query("single_rare_zzqxjv", [("zzqxjv", False, False)]),
        Query("single_cjk_contract", [("合同", False, False)]),
        Query("single_cjk_meeting_notes", [("会议纪要", False, False)]),
        Query("multi_quote_2026", [("报价", False, False), ("2026", False, False)]),
        Query("multi_final_report", [("final", False, False), ("report", False, False)]),
        Query("long_40_rare", [("a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0", False, False)]),
        Query("uppercase_Report", [("Report", False, False)]),
        Query("wildcard_rep", [("rep*", False, True)]),
        Query("category_image_screenshot", [("screenshot", False, False)], category="image"),
        Query("folder_only_project", [("project", False, False)], category="folder"),
        Query("ext_pdf_report", [("report", False, False)], extensions=["pdf"]),
        Query("scope_home_report", [("report", False, False)], scope="folders", directories=[home]),
        Query("sort_modified_report", [("report", False, False)], sort="modified"),
        Query("exclude_tmp_report", [("report", False, False), ("tmp", True, False)]),
    ]

    conn = connect(DB)
    facts = {
        "snapshot": DB,
        "snapshot_sha256_16": os.environ.get("BENCH_SHA", "unknown"),
        "rows": conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0],
        "page_size": conn.execute("PRAGMA page_size").fetchone()[0],
        "page_count": conn.execute("PRAGMA page_count").fetchone()[0],
        "freelist_count": conn.execute("PRAGMA freelist_count").fetchone()[0],
        "sqlite_version": sqlite3.sqlite_version,
        "reps": REPS,
        "limit": LIMIT,
        "run_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }

    arms = ["current", "ref", "glob", "instr", "candidate"]
    output = {"facts": facts, "queries": [], "oracle_mutant": []}
    rng = random.Random(20261123)

    for q in corpus:
        # warm every arm once (page cache + statement); ref defines the oracle first
        for arm in ["ref"] + [a for a in arms if a != "ref"] + ["mutant"]:
            result = run_query(conn, q, arm)
            if arm == "ref":
                base_sig = signature(result)
            elif arm != "mutant" and signature(result) != base_sig:
                print("ORACLE MISMATCH:", q.label, arm, file=sys.stderr)
        if signature(run_query(conn, q, "mutant")) != base_sig:
            output["oracle_mutant"].append({
                "query": q.label,
                "detected": True,
                "note": "mutant (unfolded term) produced different rows/total"
            })
        else:
            output["oracle_mutant"].append({"query": q.label, "detected": False})

        samples = {arm: [] for arm in arms}
        order = arms[:]
        for _ in range(REPS):
            rng.shuffle(order)
            for arm in order:
                start = time.perf_counter()
                run_query(conn, q, arm)
                samples[arm].append((time.perf_counter() - start) * 1000.0)

        entry = {"query": q.label, "samples_ms": samples}
        entry["median_ms"] = {arm: round(statistics.median(samples[arm]), 3) for arm in arms}
        base = statistics.median(samples["current"])
        entry["ratio"] = {arm: round(statistics.median(samples[arm]) / base, 3) for arm in arms}
        entry["speedup"] = {arm: round(base / statistics.median(samples[arm]), 3) for arm in arms}
        entry["result_rows"] = len(base_sig[0])
        entry["total"] = base_sig[1]
        entry["total_exact"] = base_sig[2]
        output["queries"].append(entry)
        print(q.label, entry["median_ms"], entry["speedup"])

    # live DB baseline, if a read-only handle can be opened
    live = os.path.expanduser("~/Library/Application Support/MiscKit/index.sqlite3")
    try:
        lconn = connect(live)
        live_latency = {}
        for q in corpus:
            start = time.perf_counter()
            run_query(lconn, q, "current")
            live_latency[q.label] = round((time.perf_counter() - start) * 1000.0, 3)
        lconn.close()
        output["live_baseline_ms"] = live_latency
        output["live_rows"] = facts["rows"]
    except Exception as exc:  # noqa: BLE001
        output["live_baseline_error"] = repr(exc)

    conn.close()
    with open(os.path.expanduser(os.environ.get("BENCH_OUT", "~/.cache/misckit-bench/result.json")), "w") as fh:
        json.dump(output, fh, indent=2, ensure_ascii=False)
    print("facts:", json.dumps(facts, ensure_ascii=False))
    print("mutant detections:", sum(1 for x in output["oracle_mutant"] if x["detected"]),
          "/", len(output["oracle_mutant"]))

if __name__ == "__main__":
    main()
