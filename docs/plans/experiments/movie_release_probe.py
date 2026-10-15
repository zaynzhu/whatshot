"""只读实验：统计电影上映日期候选，不写数据库、不联网，不用于正式同步。"""
import argparse
import datetime
import json
import re
import sqlite3
from collections import Counter
from pathlib import Path

DATE_PATTERN = re.compile(
  r"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)(?:\s*[（(]([^()（）]*)[)）])?"
)
SPECIAL_SCREENING = re.compile(
  r"电影节|影展|电影展|电影周|首映|点映|重映|festival|premiere|preview|re-release",
  re.IGNORECASE
)


def candidates(raw):
  # 非特殊场次且有标签才成为候选；这不等于独立核实了站方信息的真实性。
  labeled = []
  unlabeled = []
  for match in DATE_PATTERN.finditer(raw or ""):
    try:
      date = datetime.date.fromisoformat(match[1])
    except ValueError:
      continue
    if date.year < 1800:
      continue
    label = (match[2] or "").strip()
    if SPECIAL_SCREENING.search(label):
      continue
    (labeled if label else unlabeled).append(date.isoformat())
  return sorted(set(labeled)), sorted(set(unlabeled))


def verify():
  cases = [
    ("2025-08-29(威尼斯电影节), 2026-08-07(美国)", (["2026-08-07"], [])),
    ("2026-05-22(中国大陆), 2026-04-19(北京国际电影节)", (["2026-05-22"], [])),
    ("2026-05-12(戛纳电影节,法国)", ([], [])),
    ("2026-01-01(美国, 中国大陆)", (["2026-01-01"], [])),
    ("2026-01-01（中国大陆网络）", (["2026-01-01"], [])),
    ("2026-01-01(首映), 2026-01-02(点映), 2026-01-03(重映)", ([], [])),
    ("2026-01-01", ([], ["2026-01-01"])),
    ("2026(未定), 2025-06(电影节)", ([], [])),
    ("2026-02-30(美国)", ([], [])),
    ("2024-02-29(美国)", (["2024-02-29"], [])),
    ("12026-01-01, 2026-01-011, 2026-2-03", ([], [])),
    (None, ([], []))
  ]
  for raw, expected in cases:
    assert candidates(raw) == expected, (raw, candidates(raw), expected)
  return len(cases)


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("database", type=Path)
  parser.add_argument("--as-of", type=datetime.date.fromisoformat, required=True)
  args = parser.parse_args()
  checks = verify()
  stats = Counter()
  uri = args.database.resolve().as_uri() + "?mode=ro"
  with sqlite3.connect(uri, uri=True) as connection:
    rows = connection.execute(
      "SELECT years, release_info, premiere_date FROM videos WHERE kind = 1"
    ).fetchall()
  for year, raw, normalized in rows:
    stats["movies"] += 1
    stats["existing_normalized_dates"] += bool(normalized)
    stats["nonempty_raw"] += bool(raw and raw.strip())
    labeled, unlabeled = candidates(raw)
    recent = str(year).strip() in {str(args.as_of.year), str(args.as_of.year - 1)}
    stats["recent_movies"] += recent
    if labeled:
      date = labeled[0]
      stats["labeled_candidates"] += 1
      stats["recent_candidates"] += recent
      stats["year_differs_from_candidate"] += date[:4] != str(year).strip()
      stats["future_candidates"] += date > args.as_of.isoformat()
    elif unlabeled:
      stats["only_unlabeled_dates"] += 1
    else:
      stats["no_usable_date"] += 1
  print(json.dumps({"as_of": args.as_of.isoformat(), "boundary_checks": checks,
                    "statistics": dict(stats)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
  main()
