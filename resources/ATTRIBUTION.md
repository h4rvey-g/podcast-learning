# Vocabulary data attribution

## CEFR-J (A1–B2)

The CEFR-J Wordlist Version 1.6. Compiled by Yukio Tono, Tokyo University of Foreign Studies (Tono Laboratory).

Official source and terms: https://www.cefr-j.org/download.html

The source workbook was already present in this repository; its original retrieval date is not recorded. Attribution and terms were verified on 2026-11-02. Research, educational, and commercial use with proper acknowledgment is permitted under the source's published terms. Modifications are permitted with attribution. The source disclaims accuracy and liability.

## Octanove (C1/C2)

Octanove Vocabulary Profile C1/C2 Version 1.0, created by Octanove Labs.

Source: https://github.com/openlanguageprofiles/olp-en-cefrj

Licensed under Creative Commons Attribution–ShareAlike 4.0 International:
https://creativecommons.org/licenses/by-sa/4.0/
Legal text: https://creativecommons.org/licenses/by-sa/4.0/legalcode

The Octanove-derived C1/C2 entries in `wordlist.json` are distributed under CC BY-SA 4.0. Retain this notice and the license link when redistributing them.

## Changes in the bundled derivative

`scripts/build_wordlist.py` combines both datasets, splits slash-separated spellings, lowercases keys, maps parts of speech, fixes `vern` to `verb`, drops sense notes, and keeps the lowest level for duplicate headword/POS entries. CEFR-J entries retain their source's terms; the Octanove adaptation retains CC BY-SA 4.0. No accuracy warranty is provided.
