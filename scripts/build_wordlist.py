#!/usr/bin/env python3
"""Run: uv run --with openpyxl scripts/build_wordlist.py"""
import csv
import json
from collections import Counter
from pathlib import Path
import openpyxl

ROOT = Path(__file__).resolve().parents[1]
LEVELS = ['A1', 'A2', 'B1', 'B2', 'C1', 'C2']
POS = {'noun': 'noun', 'verb': 'verb', 'vern': 'verb', 'adjective': 'adjective', 'adverb': 'adverb'}


def build():
    workbook = openpyxl.load_workbook(ROOT / 'resources/CEFR-J Wordlist Ver1.6.xlsx', read_only=True)
    rows = list(workbook['ALL_sep'].values)[1:]
    with (ROOT / 'resources/octanove-vocabulary-profile-c1c2-1.0.csv').open(newline='', encoding='utf-8-sig') as f:
        rows += [(r['headword'], r['pos'], r['CEFR']) for r in csv.DictReader(f)]
    words = {}
    for word, pos, level, *_ in rows:
        if not word or level not in LEVELS:
            continue
        for variant in word.split('/'):
            # Lookup is case-insensitive; merge uppercase variants instead of duplicating them.
            key = variant.strip().lower()
            senses = words.setdefault(key, {})
            part = POS.get(str(pos).strip().lower(), 'other')
            old = senses.get(part)
            if old is None or LEVELS.index(level) < LEVELS.index(old):
                senses[part] = level
    counts = Counter(level for senses in words.values() for level in senses.values())
    assert sum(counts.values()) > 9000, counts
    assert set(counts) == set(LEVELS), counts
    (ROOT / 'resources/wordlist.json').write_text(json.dumps(words, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n')
    print(f'{len(words)} headwords; {dict(sorted(counts.items()))}')


if __name__ == '__main__':
    build()
