#!/usr/bin/env python3
"""Read-only: summarise the music library on a mounted iPod, for the Clickwheel app's preview.

Usage: python3 scripts/library.py /Volumes/iPod [--json]

Reads iPod_Control/iTunes/iTunesDB (never writes anything) and prints, per genre (what the Labels
patch shows as a label), the composers and artists in it with their albums (songs without a genre
are left out there), and every song with its title, artist, composer, album, genre and track/disc
number (for the preview's Songs menu and album lists).

iTunesDB layout used here: chunks start with a 4-byte tag and u32 header length; 'mhbd' (database)
holds 'mhsd' sections, type 1 = tracks, which hold an 'mhlt' list of 'mhit' tracks. Each 'mhit'
(u32 total length at +8, u32 number of strings at +12) is followed by its 'mhod' strings: u32 type at
+12, u32 byte length at +28, text at +40 (UTF-16LE; UTF-8 when the u32 at +32 is 2).
Types: 1 title, 3 album, 4 artist, 5 genre, 12 composer. In 'mhit': u32 track number at +44, u32 disc
number at +92.
"""
import json, os, struct, sys
from collections import Counter, defaultdict

FIELDS = {1: 'title', 3: 'album', 4: 'artist', 5: 'genre', 12: 'composer'}


def tracks(db):
    if db[:4] != b'mhbd':
        sys.exit('ERROR: not an iTunesDB (no mhbd header)')
    pos = struct.unpack_from('<I', db, 4)[0]
    while pos + 16 <= len(db) and db[pos:pos + 4] == b'mhsd':
        hlen, total, typ = struct.unpack_from('<III', db, pos + 4)
        if typ == 1:
            p = pos + hlen
            if db[p:p + 4] != b'mhlt':
                break
            count = struct.unpack_from('<I', db, p + 8)[0]
            p += struct.unpack_from('<I', db, p + 4)[0]
            for _ in range(count):
                if db[p:p + 4] != b'mhit':
                    return
                ihlen, itotal, nstr = struct.unpack_from('<III', db, p + 4)
                t, q = {}, p + ihlen
                if ihlen >= 96:
                    t['track'] = struct.unpack_from('<I', db, p + 44)[0]
                    t['disc'] = struct.unpack_from('<I', db, p + 92)[0]
                for _ in range(nstr):
                    if db[q:q + 4] != b'mhod':
                        break
                    otot, otype = struct.unpack_from('<I', db, q + 8)[0], struct.unpack_from('<I', db, q + 12)[0]
                    if otype in FIELDS and otot >= 40:
                        n, enc = struct.unpack_from('<II', db, q + 28)
                        raw = db[q + 40:q + 40 + n]
                        t[FIELDS[otype]] = raw.decode('utf-8' if enc == 2 else 'utf-16-le', 'replace').strip()
                    q += otot
                yield t
                p += itotal
            return
        pos += total


def summary(db, per=500):
    by_genre = defaultdict(list)
    for t in tracks(db):
        if t.get('genre'):
            by_genre[t['genre']].append(t)
    out = []
    for g, ts in sorted(by_genre.items(), key=lambda kv: (-len(kv[1]), kv[0].lower())):
        entry = {'name': g, 'songs': len(ts)}
        for role in ('composer', 'artist'):
            people = Counter(t[role] for t in ts if t.get(role))
            entry[role + 's'] = [{'name': who, 'albums': [a for a, _ in Counter(
                t['album'] for t in ts if t.get(role) == who and t.get('album')).most_common(per)]}
                for who, _ in people.most_common(per)]
        out.append(entry)
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = os.path.join(sys.argv[1], 'iPod_Control', 'iTunes', 'iTunesDB')
    try:
        db = open(path, 'rb').read()
    except OSError as e:
        sys.exit(f'ERROR: cannot read {path}: {e.strerror}')
    genres = summary(db)
    if '--json' in sys.argv:
        keys = ('title', 'artist', 'composer', 'album', 'genre', 'track', 'disc')
        songs = [{k: t[k] for k in keys if t.get(k)} for t in tracks(db) if t.get('title')][:30000]
        print(json.dumps({'ok': True, 'genres': genres[:500], 'songs': songs}))
        return
    for g in genres[:40]:
        print(f'{g["name"]} ({g["songs"]} songs): composers {len(g["composers"])}, artists {len(g["artists"])}')


if __name__ == '__main__':
    main()
